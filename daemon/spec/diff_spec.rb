# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/app"
require "relay_daemon/config"
require "relay_daemon/db"
require "relay_daemon/git"
require "relay_daemon/repo_store"
require "relay_daemon/task_store"
require "relay_daemon/task_runner"

FAKE_DIFF_AGENT = File.expand_path("support/fake_diff_agent.rb", __dir__)
FAKE_NOOP_AGENT = File.expand_path("support/fake_noop_agent.rb", __dir__)

RSpec.describe "Diff API" do
  include Rack::Test::Methods

  def app
    RelayDaemon::App
  end

  let(:db_path)       { File.join(Dir.mktmpdir, "test.sqlite3") }
  let(:db)            { RelayDaemon::Db.new(db_path) }
  let(:repo_store)    { RelayDaemon::RepoStore.new(db) }
  let(:task_store)    { RelayDaemon::TaskStore.new(db) }
  let(:token)         { "diff-test-token" }
  let(:worktrees_dir) { Dir.mktmpdir }
  let(:agent_log_dir) { Dir.mktmpdir }

  # Git repo with a pre-existing file for edit/add tests.
  let(:git_dir) do
    dir = make_git_dir
    File.write(File.join(dir, "existing.txt"), "line1\n")
    Open3.capture3("git", "-C", dir, "add", "existing.txt")
    Open3.capture3("git", "-C", dir,
                   "-c", "user.email=t@t.com",
                   "-c", "user.name=T",
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

  def post_task(prompt: "test")
    post "/tasks",
         { repoId: repo["id"], prompt: prompt, qualityDial: 5 }.to_json,
         { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
  end

  def wait_for_task(task_id, timeout: 10)
    deadline = Time.now + timeout
    loop do
      get "/tasks/#{task_id}", {}, auth_headers
      t = JSON.parse(last_response.body)
      break t if %w[needs_review failed].include?(t["status"])
      raise "timeout waiting for task #{task_id}" if Time.now > deadline

      sleep 0.05
    end
  end

  describe "GET /tasks/:id/diff" do
    it "returns per-file diffs when the agent edited and added files" do
      configure_app("ruby #{FAKE_DIFF_AGENT} {prompt}")
      post_task
      task_id = JSON.parse(last_response.body)["id"]
      wait_for_task(task_id)

      get "/tasks/#{task_id}/diff", {}, auth_headers
      expect(last_response.status).to eq(200)

      diffs = JSON.parse(last_response.body)
      expect(diffs).not_to be_empty
      files = diffs.map { |d| d["file"] }
      expect(files).to include("new.txt", "existing.txt")

      new_entry = diffs.find { |d| d["file"] == "new.txt" }
      expect(new_entry["additions"]).to be > 0
      expect(new_entry["deletions"]).to eq(0)
    end

    it "returns an empty array when the agent made no changes" do
      configure_app("ruby #{FAKE_NOOP_AGENT} {prompt}")
      post_task
      task_id = JSON.parse(last_response.body)["id"]
      wait_for_task(task_id)

      get "/tasks/#{task_id}/diff", {}, auth_headers
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq([])
    end

    it "returns 404 for an unknown task id" do
      configure_app("ruby #{FAKE_NOOP_AGENT} {prompt}")
      get "/tasks/00000000-0000-0000-0000-000000000000/diff", {}, auth_headers
      expect(last_response.status).to eq(404)
    end

    it "returns 401 without token" do
      configure_app("ruby #{FAKE_NOOP_AGENT} {prompt}")
      get "/tasks/any-id/diff"
      expect(last_response.status).to eq(401)
    end

    it "returns 503 when task_store not configured" do
      configure_app("ruby #{FAKE_NOOP_AGENT} {prompt}")
      RelayDaemon::App.set(:task_store, nil)
      get "/tasks/any-id/diff", {}, auth_headers
      expect(last_response.status).to eq(503)
    end
  end
end
