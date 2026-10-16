# frozen_string_literal: true

require "spec_helper"
require "relay_daemon/app"
require "rbconfig"

RSpec.describe RelayDaemon::HarnessCatalog do
  let(:home) { Dir.mktmpdir }
  let(:bin) { File.join(home, "bin") }
  let(:env) { { "PATH" => bin } }

  def executable(name, body)
    FileUtils.mkdir_p(bin)
    path = File.join(bin, name)
    File.write(path, "#!#{RbConfig.ruby}\n#{body}\n")
    File.chmod(0o755, path)
    path
  end

  it "discovers only runnable installations, caches and refreshes" do
    executable("claude", 'puts "claude 1.2.3"')
    executable("codex", 'puts "codex 0.10.0"')
    executable("gemini", 'warn "runtime missing"; exit 1')
    executable("omp", 'puts "not a version"')
    catalog = described_class.new(env: env, home: home, system_paths: [])
    result = catalog.catalog
    expect(result.map { |item| item["status"] }).to eq(%w[ready ready broken missing broken])
    expect(result.first["capabilities"]["permissionModes"]).to include("ask_every_time")
    expect(result.first["authStatus"]).to eq("unknown")
    executable("copilot", 'puts "copilot 1.0.0"')
    expect(catalog.catalog[3]["status"]).to eq("missing")
    expect(catalog.catalog(refresh: true)[3]["status"]).to eq("ready")
  end

  it "supports manual paths and standard per-user installation locations" do
    override = executable("custom-claude", 'puts "1.0.0"')
    local = File.join(home, ".local/bin")
    FileUtils.mkdir_p(local)
    FileUtils.cp(override, File.join(local, "codex"))
    File.chmod(0o755, File.join(local, "codex"))
    catalog = described_class.new(env: env.merge("RELAY_HARNESS_CLAUDE_PATH" => override), home: home, system_paths: [])
    expect(catalog.catalog.first).to include("path" => override, "status" => "ready")
    expect(catalog.catalog[1]["path"]).to eq(File.join(local, "codex"))
  end

  it "bounds probe output and runtime, suppresses stderr and handles vanished executables" do
    executable("claude", 'puts "claude 1.2.3"; print "x" * 20000; warn "secret"')
    executable("codex", 'sleep 60')
    env["RELAY_HARNESS_GEMINI_PATH"] = File.join(bin, "gone")
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = described_class.new(env: env, home: home, system_paths: []).catalog
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).to be < 6
    expect(result[0]["version"]).to eq("claude 1.2.3")
    expect(result[1]["status"]).to eq("broken")
    expect(result[2]["status"]).to eq("broken")
    expect(result.to_json).not_to include("secret")
  end

  it "accepts a deterministic probe seam" do
    executable("claude", "exit 0")
    paths = []
    probe = ->(path) { paths << path; { ok: true, version: "1.2.3" } }
    expect(described_class.new(env: env, home: home, system_paths: [], probe: probe).catalog.first["status"]).to eq("ready")
    expect(paths).to eq([File.join(bin, "claude")])
  end

  it "keeps quoted executable paths and prompt content as individual argv entries" do
    argv = RelayDaemon::ClaudeAdapter.build_argv('"/a path/claude" -p {prompt}', 'hello "world"; $(echo nope)', session_id: "id", resume: false)
    expect(argv).to eq(["/a path/claude", "-p", 'hello "world"; $(echo nope)', "--session-id", "id"])
  end
end

RSpec.describe "Harness discovery API" do
  include Rack::Test::Methods
  def app = RelayDaemon::App
  let(:headers) { { "HTTP_AUTHORIZATION" => "Bearer harness-token" } }
  let(:catalog) { instance_double(RelayDaemon::HarnessCatalog) }
  before do
    app.set(:relay_config, RelayDaemon::Config.new(daemon_token: "harness-token", host: "127.0.0.1", port: 7777, db_path: "unused"))
    app.set(:harness_catalog, catalog)
  end
  after { app.set(:harness_catalog, nil) }

  it "authenticates both discovery and refresh" do
    get "/harnesses"
    expect(last_response.status).to eq(401)
    post "/harnesses/refresh"
    expect(last_response.status).to eq(401)
    expect(catalog).to receive(:catalog).with(no_args).and_return([{ "id" => "claude" }])
    get "/harnesses", {}, headers
    expect(JSON.parse(last_response.body)).to eq([{ "id" => "claude" }])
    expect(catalog).to receive(:catalog).with(refresh: true).and_return([])
    post "/harnesses/refresh", "", headers
    expect(last_response.status).to eq(200)
  end

  it "constructs a catalog when one was not injected" do
    app.set(:harness_catalog, nil)
    allow(RelayDaemon::HarnessCatalog).to receive(:new).and_return(catalog)
    allow(catalog).to receive(:catalog).and_return([])
    get "/harnesses", {}, headers
    expect(last_response.status).to eq(200)
    post "/harnesses/refresh", "", headers
    expect(last_response.status).to eq(200)
  end
end
