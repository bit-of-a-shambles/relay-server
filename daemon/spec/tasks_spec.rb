# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/app"
require "relay_daemon/config"
require "relay_daemon/db"
require "relay_daemon/git"
require "relay_daemon/repo_store"
require "relay_daemon/task_store"
require "relay_daemon/task_runner"

FAKE_AGENT = File.expand_path("support/fake_agent.rb", __dir__)

# Template that passes prompt as ARGV[0]; exit code via ARGV[1] (default 0).
def agent_cmd(exit_code: 0)
  "ruby #{FAKE_AGENT} {prompt} #{exit_code}"
end

RSpec.describe "Tasks API" do
  include Rack::Test::Methods

  def app
    RelayDaemon::App
  end

  let(:db_path)     { File.join(Dir.mktmpdir, "test.sqlite3") }
  let(:db)          { RelayDaemon::Db.new(db_path) }
  let(:repo_store)  { RelayDaemon::RepoStore.new(db) }
  let(:task_store)  { RelayDaemon::TaskStore.new(db) }
  let(:token)       { "tasks-test-token" }
  let(:worktrees_dir) { Dir.mktmpdir }
  let(:agent_log_dir) { Dir.mktmpdir }

  let(:git_dir) { make_git_dir }
  let(:repo)    { repo_store.create(path: git_dir) }

  before do
    RelayDaemon::App.set(:relay_config, RelayDaemon::Config.new(
      daemon_token:   token,
      host:           "127.0.0.1",
      port:           7777,
      db_path:        db_path,
      worktrees_dir:  worktrees_dir,
      agent_log_dir:  agent_log_dir,
      agent_command:  agent_cmd
    ))
    RelayDaemon::App.set(:repo_store, repo_store)
    RelayDaemon::App.set(:task_store, task_store)
  end

  after { db.connection.close }

  def auth_headers
    { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
  end

  def post_task(body = {})
    post "/tasks",
         { repoId: repo["id"], prompt: "do the thing", qualityDial: 5 }.merge(body).to_json,
         { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
  end

  def wait_for_task(task_id, timeout: 5)
    deadline = Time.now + timeout
    loop do
      get "/tasks/#{task_id}", {}, auth_headers
      t = JSON.parse(last_response.body)
      break t if %w[needs_review failed].include?(t["status"])
      raise "timeout waiting for task #{task_id}" if Time.now > deadline

      sleep 0.05
    end
  end

  # ----- POST /tasks success -----

  describe "POST /tasks (success)" do
    it "returns 201 with task fields" do
      post_task
      expect(last_response.status).to eq(201)
      body = JSON.parse(last_response.body)
      expect(body["id"]).to be_a(String)
      expect(body["repoId"]).to eq(repo["id"])
      expect(body["prompt"]).to eq("do the thing")
      expect(body["qualityDial"]).to eq(5)
      expect(body["status"]).to eq("queued")
      expect(body["branch"]).to match(/\Arelay\//)
      expect(body["baseCommit"]).to match(/\A[0-9a-f]{40}\z/)
    end

    it "creates a worktree and runs the fake agent to completion" do
      post_task
      task_id = JSON.parse(last_response.body)["id"]
      task = wait_for_task(task_id)

      expect(task["status"]).to eq("needs_review")
      worktree = File.join(worktrees_dir, task_id)
      expect(File.exist?(File.join(worktree, "agent_ran.txt"))).to be true
      expect(File.exist?(File.join(agent_log_dir, task_id, "agent.log"))).to be true
    end

    it "passes RELAY_TASK_ID and a per-task router base URL to the agent environment" do
      post_task
      task_id = JSON.parse(last_response.body)["id"]
      wait_for_task(task_id)
      env_file = File.join(worktrees_dir, task_id, "env_task_id.txt")
      expect(File.read(env_file)).to eq(task_id)
      base_file = File.join(worktrees_dir, task_id, "env_anthropic_base.txt")
      expect(File.read(base_file)).to eq("http://127.0.0.1:7778/api/task/#{task_id}")
    end

    it "writes the learned routing config after a task finishes when configured" do
      routing_path = File.join(Dir.mktmpdir, "config", "routing.json")
      RelayDaemon::App.set(:relay_config, RelayDaemon::Config.new(
        daemon_token: token, host: "127.0.0.1", port: 7777, db_path: db_path,
        worktrees_dir: worktrees_dir, agent_log_dir: agent_log_dir,
        agent_command: agent_cmd, routing_config_path: routing_path
      ))
      post_task
      task_id = JSON.parse(last_response.body)["id"]
      wait_for_task(task_id)

      # The write happens in the task thread just after finish; poll briefly.
      deadline = Time.now + 5
      sleep 0.02 until File.exist?(routing_path) || Time.now > deadline

      expect(File.exist?(routing_path)).to be true
      parsed = JSON.parse(File.read(routing_path))
      expect(parsed["tiers"]["1"]).to eq(["moonshotai/kimi-k2", "deepseek/deepseek-chat"])
    end

    it "leaves testsPassed null when the repo has no testCommand" do
      post_task
      task_id = JSON.parse(last_response.body)["id"]
      task = wait_for_task(task_id)
      expect(task["status"]).to eq("needs_review")
      expect(task["testsPassed"]).to be_nil
    end

    it "transitions to failed when agent exits non-zero" do
      RelayDaemon::App.set(:relay_config, RelayDaemon::Config.new(
        daemon_token: token, host: "127.0.0.1", port: 7777, db_path: db_path,
        worktrees_dir: worktrees_dir, agent_log_dir: agent_log_dir,
        agent_command: agent_cmd(exit_code: 1)
      ))
      post_task
      task_id = JSON.parse(last_response.body)["id"]
      task = wait_for_task(task_id)
      expect(task["status"]).to eq("failed")
      expect(task["finishedAt"]).not_to be_nil
      expect(task["testsPassed"]).to be_nil
    end
  end

  # ----- Test runner (M10) -----

  describe "test command after agent exit" do
    def post_task_for(repo_record)
      post "/tasks",
           { repoId: repo_record["id"], prompt: "do the thing", qualityDial: 5 }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
    end

    it "sets testsPassed true when the test command passes" do
      passing_repo = repo_store.create(path: make_git_dir, test_command: "true")
      post_task_for(passing_repo)
      task_id = JSON.parse(last_response.body)["id"]
      task = wait_for_task(task_id)
      expect(task["status"]).to eq("needs_review")
      expect(task["testsPassed"]).to be true
    end

    it "sets testsPassed false when the test command fails (still needs_review)" do
      failing_repo = repo_store.create(path: make_git_dir, test_command: "false")
      post_task_for(failing_repo)
      task_id = JSON.parse(last_response.body)["id"]
      task = wait_for_task(task_id)
      expect(task["status"]).to eq("needs_review")
      expect(task["testsPassed"]).to be false
    end

    it "captures test command output in the task log" do
      echo_repo = repo_store.create(path: make_git_dir, test_command: "echo TEST_OUTPUT_MARKER")
      post_task_for(echo_repo)
      task_id = JSON.parse(last_response.body)["id"]
      wait_for_task(task_id)
      log = File.read(File.join(agent_log_dir, task_id, "agent.log"))
      expect(log).to include("TEST_OUTPUT_MARKER")
    end
  end

  # ----- POST /tasks validation -----

  describe "POST /tasks (validation)" do
    it "returns 422 when repoId is missing" do
      post "/tasks",
           { prompt: "x", qualityDial: 5 }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(422)
    end

    it "returns 422 when prompt is empty" do
      post "/tasks",
           { repoId: repo["id"], prompt: "", qualityDial: 5 }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(422)
    end

    it "returns 422 when qualityDial is out of range" do
      post "/tasks",
           { repoId: repo["id"], prompt: "x", qualityDial: 11 }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(422)
    end

    it "returns 422 when qualityDial is negative" do
      post "/tasks",
           { repoId: repo["id"], prompt: "x", qualityDial: -1 }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(422)
    end

    it "returns 422 when repo does not exist" do
      post "/tasks",
           { repoId: 99_999, prompt: "x", qualityDial: 5 }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(422)
      expect(JSON.parse(last_response.body)["error"]).to include("repo not found")
    end

    it "returns 400 on non-JSON body" do
      post "/tasks", "not json",
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(400)
    end

    it "returns 400 on non-object JSON" do
      post "/tasks", "[1,2]",
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(400)
    end

    it "returns 401 without token" do
      post "/tasks",
           { repoId: repo["id"], prompt: "x", qualityDial: 5 }.to_json,
           "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to eq(401)
    end

    it "returns 503 when repo_store not configured" do
      RelayDaemon::App.set(:repo_store, nil)
      post_task
      expect(last_response.status).to eq(503)
    end

    it "returns 503 when task_store not configured" do
      RelayDaemon::App.set(:task_store, nil)
      post_task
      expect(last_response.status).to eq(503)
    end

    it "returns 503 when agent_command not configured" do
      RelayDaemon::App.set(:relay_config, RelayDaemon::Config.new(
        daemon_token: token, host: "127.0.0.1", port: 7777, db_path: db_path,
        worktrees_dir: worktrees_dir, agent_log_dir: agent_log_dir,
        agent_command: nil
      ))
      post_task
      expect(last_response.status).to eq(503)
    end
  end

  # ----- GET /tasks/:id -----

  describe "GET /tasks/:id" do
    it "returns the task JSON" do
      post_task
      task_id = JSON.parse(last_response.body)["id"]
      get "/tasks/#{task_id}", {}, auth_headers
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["id"]).to eq(task_id)
    end

    it "returns 404 for unknown task id" do
      get "/tasks/00000000-0000-0000-0000-000000000000", {}, auth_headers
      expect(last_response.status).to eq(404)
    end

    it "returns 401 without token" do
      get "/tasks/any-id"
      expect(last_response.status).to eq(401)
    end

    it "returns 503 when task_store not configured" do
      RelayDaemon::App.set(:task_store, nil)
      get "/tasks/any-id", {}, auth_headers
      expect(last_response.status).to eq(503)
    end
  end

  # ----- GET /tasks -----

  describe "GET /tasks" do
    before do
      post_task
      post "/tasks",
           { repoId: repo["id"], prompt: "second prompt", qualityDial: 3 }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
    end

    it "returns all tasks for the daemon as an array" do
      get "/tasks", {}, auth_headers
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body).to be_an(Array)
      expect(body.size).to eq(2)
      expect(body.map { |t| t["prompt"] }).to include("do the thing", "second prompt")
    end

    it "filters by repoId when ?repoId= is given" do
      other_dir  = make_git_dir
      other_repo = repo_store.create(path: other_dir)
      post "/tasks",
           { repoId: other_repo["id"], prompt: "other repo task", qualityDial: 1 }.to_json,
           { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)

      get "/tasks?repoId=#{repo["id"]}", {}, auth_headers
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body.all? { |t| t["repoId"] == repo["id"] }).to be true
      expect(body.none? { |t| t["prompt"] == "other repo task" }).to be true
    end

    it "returns 422 for a non-numeric repoId" do
      get "/tasks?repoId=abc", {}, auth_headers
      expect(last_response.status).to eq(422)
    end

    it "returns 401 without token" do
      get "/tasks"
      expect(last_response.status).to eq(401)
    end

    it "returns 503 when task_store not configured" do
      RelayDaemon::App.set(:task_store, nil)
      get "/tasks", {}, auth_headers
      expect(last_response.status).to eq(503)
    end
  end
end

RSpec.describe RelayDaemon::TaskStore do
  let(:db_path) { File.join(Dir.mktmpdir, "test.sqlite3") }
  let(:db)      { RelayDaemon::Db.new(db_path) }
  after { db.connection.close }

  subject(:store) { described_class.new(db) }

  let(:git_dir) { make_git_dir }
  let(:repo_id) do
    RelayDaemon::RepoStore.new(db).create(path: git_dir)["id"]
  end

  describe "#create" do
    it "inserts a queued task and returns its hash" do
      task = store.create(repo_id: repo_id, prompt: "p", quality_dial: 3, branch: "relay/x")
      expect(task["status"]).to eq("queued")
      expect(task["id"]).to match(/\A[0-9a-f-]{36}\z/)
      expect(task["repoId"]).to eq(repo_id)
    end
  end

  describe "#find" do
    it "returns nil for unknown id" do
      expect(store.find("nonexistent")).to be_nil
    end

    it "returns the task for a known id" do
      task = store.create(repo_id: repo_id, prompt: "p", quality_dial: 3, branch: "relay/x")
      found = store.find(task["id"])
      expect(found["prompt"]).to eq("p")
    end
  end

  describe "#update_status" do
    it "updates status without finished_at" do
      task = store.create(repo_id: repo_id, prompt: "p", quality_dial: 3, branch: "relay/x")
      store.update_status(task["id"], "running")
      expect(store.find(task["id"])["status"]).to eq("running")
    end

    it "updates status with finished_at" do
      task = store.create(repo_id: repo_id, prompt: "p", quality_dial: 3, branch: "relay/x")
      ts = Time.now.utc.iso8601
      store.update_status(task["id"], "failed", finished_at: ts)
      found = store.find(task["id"])
      expect(found["status"]).to eq("failed")
      expect(found["finishedAt"]).to eq(ts)
    end
  end

  describe "#finish" do
    def insert_llm_call(task_id, cost:, frontier:)
      db.connection.execute(
        "INSERT INTO llm_calls (task_id, requested_model, routed_model, tier,
           prompt_tokens, completion_tokens, cost_usd, frontier_cost_usd,
           latency_ms, status, created_at)
         VALUES (?, 'm', 'm', 1, 10, 10, ?, ?, 100, 'ok', ?)",
        [task_id, cost, frontier, Time.now.utc.iso8601]
      )
    end

    it "aggregates costs from llm_calls and computes savedUsd" do
      task = store.create(repo_id: repo_id, prompt: "p", quality_dial: 3, branch: "relay/x")
      insert_llm_call(task["id"], cost: 0.01, frontier: 0.05)
      insert_llm_call(task["id"], cost: 0.02, frontier: 0.10)

      store.finish(task["id"], status: "needs_review", tests_passed: 1)
      found = store.find(task["id"])
      expect(found["status"]).to eq("needs_review")
      expect(found["testsPassed"]).to be true
      expect(found["costUsd"]).to be_within(0.0001).of(0.03)
      expect(found["savedUsd"]).to be_within(0.0001).of(0.12)
      expect(found["finishedAt"]).not_to be_nil
    end

    it "leaves costs null when no llm_calls exist for the task" do
      task = store.create(repo_id: repo_id, prompt: "p", quality_dial: 3, branch: "relay/x")
      store.finish(task["id"], status: "failed", tests_passed: nil)
      found = store.find(task["id"])
      expect(found["costUsd"]).to be_nil
      expect(found["savedUsd"]).to be_nil
      expect(found["testsPassed"]).to be_nil
    end

    it "converts tests_passed 0 to false" do
      task = store.create(repo_id: repo_id, prompt: "p", quality_dial: 3, branch: "relay/x")
      store.finish(task["id"], status: "needs_review", tests_passed: 0)
      expect(store.find(task["id"])["testsPassed"]).to be false
    end
  end

  describe "#all" do
    it "returns all tasks ordered newest-first" do
      repo_id2 = RelayDaemon::RepoStore.new(db).create(path: make_git_dir)["id"]
      t1 = store.create(repo_id: repo_id, prompt: "first",  quality_dial: 1, branch: "relay/a")
      t2 = store.create(repo_id: repo_id2, prompt: "second", quality_dial: 2, branch: "relay/b")
      tasks = store.all
      expect(tasks.map { |t| t["id"] }).to include(t1["id"], t2["id"])
    end

    it "returns empty array when no tasks" do
      expect(store.all).to eq([])
    end
  end

  describe "#all_for_repo" do
    it "returns only tasks for the given repo, newest-first" do
      repo_id2 = RelayDaemon::RepoStore.new(db).create(path: make_git_dir)["id"]
      t1 = store.create(repo_id: repo_id,  prompt: "mine",  quality_dial: 1, branch: "relay/a")
      t2 = store.create(repo_id: repo_id2, prompt: "other", quality_dial: 2, branch: "relay/b")
      t3 = store.create(repo_id: repo_id,  prompt: "also mine", quality_dial: 1, branch: "relay/c")

      tasks = store.all_for_repo(repo_id)
      expect(tasks.map { |t| t["id"] }).to include(t1["id"], t3["id"])
      expect(tasks.map { |t| t["id"] }).not_to include(t2["id"])
      expect(tasks.all? { |t| t["repoId"] == repo_id }).to be true
    end

    it "returns empty array for a repo with no tasks" do
      expect(store.all_for_repo(repo_id)).to eq([])
    end
  end
end

RSpec.describe RelayDaemon::TaskRunner do
  describe ".build_argv" do
    it "replaces {prompt} with the prompt string" do
      argv = described_class.build_argv("ruby /fake.rb {prompt}", "hello world")
      expect(argv).to eq(["ruby", "/fake.rb", "hello world"])
    end

    it "leaves other args unchanged" do
      argv = described_class.build_argv("ruby /fake.rb --flag", "ignored")
      expect(argv).to eq(["ruby", "/fake.rb", "--flag"])
    end
  end
end
