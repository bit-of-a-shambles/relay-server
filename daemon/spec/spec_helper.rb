# frozen_string_literal: true

require "simplecov"
SimpleCov.start do
  enable_coverage :branch
  add_filter "/spec/"
  track_files "lib/**/*.rb"
  minimum_coverage 100
end

$LOAD_PATH.unshift File.join(__dir__, "..", "lib")

require "rack/test"
require "json"
require "open3"
require "tmpdir"

# Shared helper: create a temp git repo with an initial commit.
def make_git_dir
  dir = Dir.mktmpdir
  Open3.capture3("git", "-C", dir, "init")
  Open3.capture3("git", "-C", dir,
                 "-c", "user.email=t@t.com",
                 "-c", "user.name=T",
                 "-c", "commit.gpgsign=false",
                 "commit", "--allow-empty", "-m", "init")
  dir
end
