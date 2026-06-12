# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/app"
require "relay_daemon/config"
require "relay_daemon/db"
require "relay_daemon/git"
require "relay_daemon/repo_store"
require "relay_daemon/task_store"
require "relay_daemon/task_runner"

DIFF_AGENT = File.expand_path("support/fake_diff_agent.rb", __dir__)
NOOP_AGENT = File.expand_path("support/fake_noop_agent.rb", __dir__)

RSpec.describe "Approve/Reject API" do
  include Rack::Test::Methods

  def app
    RelayDaemon::App
  end

  let(:db_path)       { File.join(Dir.mktmpdir, "test.sqlite3") }
  let(:db)            { RelayDaemon::Db.new(db_path) }
  let(:repo_store)    { RelayDaemon::RepoStore.new(db) }
  let(:task_store)    { RelayDaemon::TaskStore.new(db) }
  let(:token)         { "approve-test-token" }
  let(:worktrees_dir) { Dir.mktmpdir }
  let(:agent_log_dir) { Dir.mktmpdir }

  # Git repo with a pre-existing file the diff agent will edit.
  let(:git_dir) do
    dir = make_git_dir
    File.write(File.join(dir, "existing.txt"), "line1\n")
    Open3.capture3("git", "-C", dir, "add", "existing.txt")
    Open3.capture3("git", "-C", dir,
                   "-c", "user.email=t@t.com", "-c", "user.name=T",
                   "-c", "commit.gpgsign=false",
                   "commit", "-m", "add existing file")
    dir
  end

  let(:repo) { repo_store.create(path: git_dir) }

  after { db.connection.close }

  def configure_app(agent_command)
    RelayDaemon::App.set(:relay_config, RelayDaemon::Config.new(
      daemon_token: token, host: "127.0.0.1", port: 7777, db_path: db_path,
      worktrees_dir: worktrees_dir, agent_log_dir: agent_log_dir,
      agent_command: agent_command
    ))
    RelayDaemon::App.set(:repo_store, repo_store)
    RelayDaemon::App.set(:task_store, task_store)
  end

  def auth_headers
    { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
  end

  def run_task_to(status_wanted, agent: NOOP_AGENT)
    configure_app("ruby #{agent} {prompt}")
    post "/tasks",
         { repoId: repo["id"], prompt: "x", qualityDial: 5 }.to_json,
         { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
    task_id = JSON.parse(last_response.body)["id"]
    deadline = Time.now + 10
    loop do
      get "/tasks/#{task_id}", {}, auth_headers
      t = JSON.parse(last_response.body)
      break t if t["status"] == status_wanted
      raise "task reached #{t["status"]}, wanted #{status_wanted}" if %w[needs_review failed].include?(t["status"])
      raise "timeout" if Time.now > deadline

      sleep 0.05
    end
  end

  def base_commit_count
    out, = Open3.capture3("git", "-C", git_dir, "rev-list", "--count", "HEAD")
    out.strip.to_i
  end

  def commit_on_base(file, content)
    File.write(File.join(git_dir, file), content)
    Open3.capture3("git", "-C", git_dir, "add", file)
    Open3.capture3("git", "-C", git_dir,
                   "-c", "user.email=t@t.com", "-c", "user.name=T",
                   "-c", "commit.gpgsign=false",
                   "commit", "-m", "base change")
  end

  describe "POST /tasks/:id/approve" do
    it "fast-forwards when the base branch has not moved" do
      task = run_task_to("needs_review", agent: DIFF_AGENT)
      before_sha, = Open3.capture3("git", "-C", git_dir, "rev-parse", "HEAD")

      post "/tasks/#{task["id"]}/approve", "", auth_headers
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["status"]).to eq("approved")

      after_sha, = Open3.capture3("git", "-C", git_dir, "rev-parse", "HEAD")
      expect(after_sha).not_to eq(before_sha)
      # Agent's file landed on the base branch
      expect(File.exist?(File.join(git_dir, "new.txt"))).to be true
      # Worktree removed, branch kept
      expect(Dir.exist?(File.join(worktrees_dir, task["id"]))).to be false
      out, = Open3.capture3("git", "-C", git_dir, "branch", "--list", task["branch"])
      expect(out).to include(task["branch"])
    end

    it "creates a merge commit when the base branch diverged (non-conflicting)" do
      task = run_task_to("needs_review", agent: DIFF_AGENT)
      commit_on_base("other.txt", "independent change\n")

      post "/tasks/#{task["id"]}/approve", "", auth_headers
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["status"]).to eq("approved")

      # Merge commit has two parents
      parents, = Open3.capture3("git", "-C", git_dir, "rev-list", "--parents", "-n", "1", "HEAD")
      expect(parents.strip.split.length).to eq(3)
      expect(File.exist?(File.join(git_dir, "new.txt"))).to be true
      expect(File.exist?(File.join(git_dir, "other.txt"))).to be true
    end

    it "returns 409 merge_conflict and keeps the task needs_review on conflict" do
      task = run_task_to("needs_review", agent: DIFF_AGENT)
      # Conflicting change to the same file the agent edited
      commit_on_base("existing.txt", "conflicting content\n")

      post "/tasks/#{task["id"]}/approve", "", auth_headers
      expect(last_response.status).to eq(409)
      expect(JSON.parse(last_response.body)["error"]).to eq("merge_conflict")

      get "/tasks/#{task["id"]}", {}, auth_headers
      expect(JSON.parse(last_response.body)["status"]).to eq("needs_review")
      # Working tree restored (no in-progress merge)
      expect(File.exist?(File.join(git_dir, ".git", "MERGE_HEAD"))).to be false
    end

    it "returns 409 when the base branch is not checked out" do
      task = run_task_to("needs_review")
      Open3.capture3("git", "-C", git_dir, "checkout", "-b", "user-switched-away")

      post "/tasks/#{task["id"]}/approve", "", auth_headers
      expect(last_response.status).to eq(409)
      expect(JSON.parse(last_response.body)["error"]).to include("not checked out")
    end

    it "returns 500 when the merge fails for a non-conflict reason" do
      task = run_task_to("needs_review")
      # Make the scratch branch unmergeable by deleting it (worktree first)
      git = RelayDaemon::Git.new(git_dir)
      git.worktree_remove(File.join(worktrees_dir, task["id"]))
      git.delete_branch(task["branch"])

      post "/tasks/#{task["id"]}/approve", "", auth_headers
      expect(last_response.status).to eq(500)
      expect(JSON.parse(last_response.body)["error"]).to include("git merge failed")
    end

    it "returns 409 when the task is not needs_review" do
      task = run_task_to("needs_review")
      post "/tasks/#{task["id"]}/approve", "", auth_headers
      expect(last_response.status).to eq(200)
      # Second approve: task is now approved
      post "/tasks/#{task["id"]}/approve", "", auth_headers
      expect(last_response.status).to eq(409)
    end

    it "returns 404 for unknown task" do
      configure_app("ruby #{NOOP_AGENT} {prompt}")
      post "/tasks/00000000-0000-0000-0000-000000000000/approve", "", auth_headers
      expect(last_response.status).to eq(404)
    end

    it "returns 401 without token" do
      configure_app("ruby #{NOOP_AGENT} {prompt}")
      post "/tasks/any/approve"
      expect(last_response.status).to eq(401)
    end

    it "returns 503 when task store not configured" do
      configure_app("ruby #{NOOP_AGENT} {prompt}")
      RelayDaemon::App.set(:task_store, nil)
      post "/tasks/any/approve", "", auth_headers
      expect(last_response.status).to eq(503)
    end

    it "returns 503 when repo store not configured" do
      configure_app("ruby #{NOOP_AGENT} {prompt}")
      RelayDaemon::App.set(:repo_store, nil)
      post "/tasks/any/approve", "", auth_headers
      expect(last_response.status).to eq(503)
    end
  end

  describe "POST /tasks/:id/reject" do
    it "rejects a needs_review task: removes worktree and deletes branch" do
      task = run_task_to("needs_review", agent: DIFF_AGENT)

      post "/tasks/#{task["id"]}/reject", "", auth_headers
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["status"]).to eq("rejected")

      expect(Dir.exist?(File.join(worktrees_dir, task["id"]))).to be false
      out, = Open3.capture3("git", "-C", git_dir, "branch", "--list", task["branch"])
      expect(out.strip).to be_empty
      # Base branch untouched
      expect(File.exist?(File.join(git_dir, "new.txt"))).to be false
    end

    it "rejects a failed task" do
      configure_app("ruby #{File.expand_path("support/fake_agent.rb", __dir__)} {prompt} 1")
      post "/tasks",
           { repoId: repo["id"], prompt: "x", qualityDial: 5 }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      task_id = JSON.parse(last_response.body)["id"]
      deadline = Time.now + 10
      loop do
        get "/tasks/#{task_id}", {}, auth_headers
        break if JSON.parse(last_response.body)["status"] == "failed"
        raise "timeout" if Time.now > deadline

        sleep 0.05
      end

      post "/tasks/#{task_id}/reject", "", auth_headers
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["status"]).to eq("rejected")
    end

    it "returns 409 when the task is already approved" do
      task = run_task_to("needs_review")
      post "/tasks/#{task["id"]}/approve", "", auth_headers
      post "/tasks/#{task["id"]}/reject", "", auth_headers
      expect(last_response.status).to eq(409)
    end

    it "returns 404 for unknown task" do
      configure_app("ruby #{NOOP_AGENT} {prompt}")
      post "/tasks/00000000-0000-0000-0000-000000000000/reject", "", auth_headers
      expect(last_response.status).to eq(404)
    end

    it "returns 401 without token" do
      configure_app("ruby #{NOOP_AGENT} {prompt}")
      post "/tasks/any/reject"
      expect(last_response.status).to eq(401)
    end

    it "returns 503 when task store not configured" do
      configure_app("ruby #{NOOP_AGENT} {prompt}")
      RelayDaemon::App.set(:task_store, nil)
      post "/tasks/any/reject", "", auth_headers
      expect(last_response.status).to eq(503)
    end

    it "returns 503 when repo store not configured" do
      configure_app("ruby #{NOOP_AGENT} {prompt}")
      RelayDaemon::App.set(:repo_store, nil)
      post "/tasks/any/reject", "", auth_headers
      expect(last_response.status).to eq(503)
    end
  end
end
