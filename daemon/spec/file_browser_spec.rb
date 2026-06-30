# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "relay_daemon/app"
require "relay_daemon/config"
require "relay_daemon/file_browser"

RSpec.describe "File browser API" do
  include Rack::Test::Methods

  def app
    RelayDaemon::App
  end

  let(:token) { "fs-test-token" }
  let(:root)  { Dir.mktmpdir }

  before do
    RelayDaemon::App.set(:relay_config, RelayDaemon::Config.new(
      daemon_token: token, host: "127.0.0.1", port: 7777, db_path: File.join(Dir.mktmpdir, "test.sqlite3")
    ))
  end

  def auth_headers
    { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
  end

  describe "GET /fs/entries" do
    it "requires auth" do
      get "/fs/entries", path: root
      expect(last_response.status).to eq(401)
    end

    it "lists child directories sorted by name and omits files" do
      FileUtils.mkdir_p(File.join(root, "zeta"))
      FileUtils.mkdir_p(File.join(root, "Alpha"))
      File.write(File.join(root, "notes.txt"), "not a directory")

      get "/fs/entries", { path: root }, auth_headers

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["path"]).to eq(root)
      expect(body["parentPath"]).to eq(File.dirname(root))
      expect(body["isGitRepo"]).to be false
      expect(body["entries"].map { |entry| entry["name"] }).to eq(["Alpha", "zeta"])
      expect(body["entries"]).to all(include("isDirectory" => true))
    end

    it "marks Git repository directories" do
      git_dir = File.join(root, "repo")
      FileUtils.mkdir_p(File.join(git_dir, ".git"))

      get "/fs/entries", { path: root }, auth_headers

      repo = JSON.parse(last_response.body)["entries"].find { |entry| entry["name"] == "repo" }
      expect(repo["path"]).to eq(git_dir)
      expect(repo["isGitRepo"]).to be true
    end

    it "returns 422 for a missing path" do
      get "/fs/entries", { path: File.join(root, "missing") }, auth_headers

      expect(last_response.status).to eq(422)
      expect(JSON.parse(last_response.body)["error"]).to include("does not exist")
    end

    it "returns 422 when the path is a file" do
      file = File.join(root, "file.txt")
      File.write(file, "x")

      get "/fs/entries", { path: file }, auth_headers

      expect(last_response.status).to eq(422)
      expect(JSON.parse(last_response.body)["error"]).to include("not a directory")
    end
  end
end

RSpec.describe RelayDaemon::FileBrowser do
  it "defaults an empty path to the current user's home directory" do
    result = described_class.new.list(path: "")

    expect(result["path"]).to eq(File.expand_path("~"))
    expect(result["entries"]).to be_an(Array)
  end

  it "has no parent at the filesystem root" do
    result = described_class.new.list(path: "/")

    expect(result["parentPath"]).to be_nil
  end

  it "marks the current directory when it is a Git repository" do
    root = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(root, ".git"))

    result = described_class.new.list(path: root)

    expect(result["isGitRepo"]).to be true
  end

  it "skips child directories that cannot be inspected" do
    root = Dir.mktmpdir
    allowed = File.join(root, "allowed")
    denied = File.join(root, "denied")
    FileUtils.mkdir_p(allowed)

    allow(Dir).to receive(:children).with(root).and_return(["denied", "allowed"])
    allow(File).to receive(:directory?).and_call_original
    allow(File).to receive(:directory?).with(denied).and_raise(Errno::EACCES)

    result = described_class.new.list(path: root)

    expect(result["entries"].map { |entry| entry["name"] }).to eq(["allowed"])
  end

  it "reports permission errors when the directory cannot be listed" do
    root = Dir.mktmpdir
    allow(Dir).to receive(:children).with(root).and_raise(Errno::EACCES)

    expect { described_class.new.list(path: root) }.to raise_error(ArgumentError, "permission denied")
  end
end
