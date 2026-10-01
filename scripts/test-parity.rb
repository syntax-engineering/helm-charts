#!/usr/bin/env ruby
# frozen_string_literal: true

# For each charts/syntax-workload/tests/parity/<app>/, the chart rendered with values.yaml must
# produce the same resources as the legacy manifests in expected/, ignoring order and formatting.

require "open3"
require "tmpdir"
require "yaml"

CHART = "charts/syntax-workload"

# Parses every YAML document in the given strings into one list of resources.
def resources(*yaml_strings)
  yaml_strings.flat_map { |s| YAML.load_stream(s) }.compact
end

# Sorts hash keys recursively so two equal resources dump to identical text.
def canonical(value)
  case value
  when Hash then value.sort.to_h { |k, v| [k, canonical(v)] }
  when Array then value.map { |v| canonical(v) }
  else value
  end
end

# One comparable YAML document per resource, ordered by kind, namespace, and name.
def normalize(list)
  list
    .sort_by { |r| [r["kind"], r.dig("metadata", "namespace").to_s, r.dig("metadata", "name")] }
    .map { |r| canonical(r).to_yaml }
    .join
end

def render(app, dir)
  out, err, status = Open3.capture3("helm", "template", app, CHART, "-f", File.join(dir, "values.yaml"))
  abort "parity: helm template failed for #{app}\n#{err}" unless status.success?
  out
end

def unified_diff(expected, rendered)
  Dir.mktmpdir("parity") do |tmp|
    File.write(File.join(tmp, "expected"), expected)
    File.write(File.join(tmp, "rendered"), rendered)
    out, = Open3.capture2("diff", "-u", "expected", "rendered", chdir: tmp)
    out
  end
end

apps = Dir.glob(File.join(CHART, "tests/parity/*/")).sort
abort "parity: no apps found under #{CHART}/tests/parity" if apps.empty?

failed = apps.reject do |dir|
  app = File.basename(dir)
  expected_files = Dir.glob(File.join(dir, "expected/*.{yml,yaml}")).sort
  abort "parity: #{app} has no expected manifests" if expected_files.empty?

  expected = normalize(resources(*expected_files.map { |f| File.read(f) }))
  rendered = normalize(resources(render(app, dir)))

  if expected == rendered
    puts "parity: #{app} matches"
    true
  else
    puts unified_diff(expected, rendered)
    puts "parity: #{app} DIFFERS (lines starting with + are what the chart adds)"
    false
  end
end

exit(failed.empty? ? 0 : 1)
