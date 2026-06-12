#!/usr/bin/env ruby
# frozen_string_literal: true
# Fake diff agent: edits existing.txt (appends) and creates new.txt.
File.write("new.txt", "created by agent\n")
File.open("existing.txt", "a") { |f| f.write("appended\n") } if File.exist?("existing.txt")
exit 0
