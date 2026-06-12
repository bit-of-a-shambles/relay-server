# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/app"
require "relay_daemon/config"
require "relay_daemon/db"
require "relay_daemon/git"
require "relay_daemon/repo_store"

RSpec.describe "Repos API" do
  include Rack::Test::Methods

  def app
    RelayDaemon::App
  end

  let(:db_path) { File.join(Dir.mktmpdir, "test.sqlite3") }
  let(:db)      { RelayDaemon::Db.new(db_path) }
  let(:store)   { RelayDaemon::RepoStore.new(db) }
  let(:token)   { "repos-test-token" }

  let(:git_dir)  { make_git_dir }
  let(:plain_dir) { Dir.mktmpdir }

  before do
    RelayDaemon::App.set(:relay_config, RelayDaemon::Config.new(
      daemon_token: token, host: "127.0.0.1", port: 7777, db_path: db_path
    ))
    RelayDaemon::App.set(:repo_store, store)
  end

  after { db.connection.close }

  def auth_headers
    { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
  end

  # ----- GET /repos -----

  describe "GET /repos" do
    it "returns 200 and empty array initially" do
      get "/repos", {}, auth_headers
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq([])
    end

    it "returns 401 without token" do
      get "/repos"
      expect(last_response.status).to eq(401)
    end

    it "returns 503 when repo store not configured" do
      RelayDaemon::App.set(:repo_store, nil)
      get "/repos", {}, auth_headers
      expect(last_response.status).to eq(503)
    end

    it "lists registered repos" do
      store.create(path: git_dir)
      get "/repos", {}, auth_headers
      repos = JSON.parse(last_response.body)
      expect(repos.length).to eq(1)
      expect(repos.first["path"]).to eq(git_dir)
    end
  end

  # ----- POST /repos -----

  describe "POST /repos (success)" do
    before do
      post "/repos",
           { path: git_dir }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
    end

    it "returns 201" do
      expect(last_response.status).to eq(201)
    end

    it "returns the repo object with id, path, name, testCommand" do
      body = JSON.parse(last_response.body)
      expect(body["id"]).to be_a(Integer)
      expect(body["path"]).to eq(git_dir)
      expect(body["name"]).to eq(File.basename(git_dir))
      expect(body["testCommand"]).to be_nil
    end

    it "accepts an optional testCommand" do
      dir2 = make_git_dir
      post "/repos",
           { path: dir2, testCommand: "npm test" }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(JSON.parse(last_response.body)["testCommand"]).to eq("npm test")
    end
  end

  describe "POST /repos (validation)" do
    it "returns 422 when path is missing" do
      post "/repos", {}.to_json, { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(422)
    end

    it "returns 422 when path does not exist" do
      post "/repos",
           { path: "/nonexistent/path/#{SecureRandom.hex}" }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(422)
      expect(JSON.parse(last_response.body)["error"]).to include("does not exist")
    end

    it "returns 422 when path is not a git repo" do
      post "/repos",
           { path: plain_dir }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(422)
      expect(JSON.parse(last_response.body)["error"]).to include("git")
    end

    it "returns 409 on duplicate path" do
      store.create(path: git_dir)
      post "/repos",
           { path: git_dir }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(409)
    end

    it "returns 400 on non-JSON body" do
      post "/repos", "not json",
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(400)
    end

    it "returns 401 without token" do
      post "/repos", { path: git_dir }.to_json, "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to eq(401)
    end

    it "returns 503 when repo store not configured" do
      RelayDaemon::App.set(:repo_store, nil)
      post "/repos",
           { path: git_dir }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(503)
    end
  end
end

RSpec.describe RelayDaemon::RepoStore do
  let(:db_path) { File.join(Dir.mktmpdir, "test.sqlite3") }
  let(:db)      { RelayDaemon::Db.new(db_path) }

  after { db.connection.close }

  subject(:store) { described_class.new(db) }

  let(:git_dir) { make_git_dir }

  describe "#find" do
    it "returns nil for unknown id" do
      expect(store.find(999)).to be_nil
    end

    it "returns the repo hash for a known id" do
      repo = store.create(path: git_dir)
      found = store.find(repo["id"])
      expect(found["path"]).to eq(git_dir)
    end
  end
end

RSpec.describe RelayDaemon::Git do
  let(:dir) { make_git_dir }

  subject(:git) { described_class.new(dir) }

  describe "#repo?" do
    it "returns true for a git repo" do
      expect(git.repo?).to be true
    end

    it "returns false for a plain directory" do
      expect(described_class.new(Dir.mktmpdir).repo?).to be false
    end
  end

  describe "#current_branch and #head_sha" do
    it "returns the current branch name" do
      expect(git.current_branch).to match(/\Amain\z|\Amaster\z/)
    end

    it "raises GitError when current_branch fails (empty repo)" do
      empty = Dir.mktmpdir
      Open3.capture3("git", "-C", empty, "init")
      expect { described_class.new(empty).current_branch }.to raise_error(described_class::GitError)
    end

    it "returns a 40-char SHA" do
      expect(git.head_sha).to match(/\A[0-9a-f]{40}\z/)
    end

    it "raises GitError when head_sha fails (empty repo)" do
      empty = Dir.mktmpdir
      Open3.capture3("git", "-C", empty, "init")
      expect { described_class.new(empty).head_sha }.to raise_error(described_class::GitError)
    end
  end

  describe "#commit_all" do
    it "creates a commit from working tree changes" do
      File.write(File.join(dir, "new.txt"), "hello")
      expect { git.commit_all("test commit") }.not_to raise_error
      out, = Open3.capture3("git", "-C", dir, "log", "--oneline")
      expect(out).to include("test commit")
    end

    it "raises GitError when not in a git repo" do
      plain = Dir.mktmpdir
      expect { described_class.new(plain).commit_all("fail") }.to raise_error(described_class::GitError)
    end
  end

  describe "#worktree_add / #worktree_remove" do
    it "creates and removes a worktree" do
      dest = Dir.mktmpdir
      FileUtils.rmdir(dest) # worktree_add expects dest not to exist
      branch = "relay/test-#{SecureRandom.hex(4)}"
      git.worktree_add(dest, branch: branch)
      expect(Dir.exist?(dest)).to be true
      git.worktree_remove(dest)
      git.delete_branch(branch)
    end

    it "raises GitError on worktree_add when dest is non-empty" do
      existing = Dir.mktmpdir
      File.write(File.join(existing, "sentinel"), "x")
      expect { git.worktree_add(existing, branch: "relay/fail") }.to raise_error(described_class::GitError)
    end

    it "raises GitError on worktree_remove for non-worktree path" do
      plain = Dir.mktmpdir
      expect { git.worktree_remove(plain) }.to raise_error(described_class::GitError)
    end
  end

  describe "#delete_branch" do
    it "raises GitError for a non-existent branch" do
      expect { git.delete_branch("relay/does-not-exist") }.to raise_error(described_class::GitError)
    end
  end

  describe "#diff_files" do
    it "returns empty array when nothing changed" do
      expect(git.diff_files(git.head_sha)).to eq([])
    end

    it "returns empty array for an invalid ref" do
      expect(git.diff_files("0000000000000000000000000000000000000000")).to eq([])
    end

    it "returns diff info after a change" do
      File.write(File.join(dir, "a.txt"), "hello\n")
      git.commit_all("add file")
      base_sha = git.head_sha

      worktree = Dir.mktmpdir
      FileUtils.rmdir(worktree)
      branch = "relay/diff-test-#{SecureRandom.hex(4)}"
      git.worktree_add(worktree, branch: branch)
      File.write(File.join(worktree, "a.txt"), "hello\nworld\n")
      wt_git = described_class.new(worktree)
      wt_git.commit_all("modify")

      diffs2 = wt_git.diff_files(base_sha)
      git.worktree_remove(worktree)
      git.delete_branch(branch)

      expect(diffs2).not_to be_empty
      expect(diffs2.first["file"]).to eq("a.txt")
      expect(diffs2.first["additions"]).to be > 0
    end

    it "skips malformed numstat lines" do
      # Exercise the `next unless parts.length == 3` branch in parse_diff
      result = git.send(:parse_diff, "malformed\n1\t0\tb.txt\n", "")
      expect(result.length).to eq(1)
      expect(result.first["file"]).to eq("b.txt")
    end
  end

  describe "#merge" do
    it "merges a non-conflicting branch successfully" do
      branch = "relay/ok-#{SecureRandom.hex(4)}"
      worktree = Dir.mktmpdir
      FileUtils.rmdir(worktree)
      git.worktree_add(worktree, branch: branch)
      File.write(File.join(worktree, "new.txt"), "new\n")
      described_class.new(worktree).commit_all("add file")

      expect { git.merge(branch) }.not_to raise_error
      git.worktree_remove(worktree)
      git.delete_branch(branch)
    end

    it "raises GitError with 'merge_conflict' message on conflict" do
      branch = "relay/conflict-#{SecureRandom.hex(4)}"
      File.write(File.join(dir, "conflict.txt"), "base\n")
      git.commit_all("base file")

      worktree = Dir.mktmpdir
      FileUtils.rmdir(worktree)
      git.worktree_add(worktree, branch: branch)

      File.write(File.join(worktree, "conflict.txt"), "branch version\n")
      described_class.new(worktree).commit_all("branch change")

      File.write(File.join(dir, "conflict.txt"), "main version\n")
      git.commit_all("main change")

      expect { git.merge(branch) }.to raise_error(described_class::GitError, /merge_conflict/)
      Open3.capture3("git", "-C", dir, "merge", "--abort")
      git.worktree_remove(worktree)
      git.delete_branch(branch)
    end

    it "raises GitError (not merge_conflict) for non-existent branch" do
      expect { git.merge("relay/nonexistent-branch") }.to raise_error(described_class::GitError, /git merge failed/)
    end
  end
end
