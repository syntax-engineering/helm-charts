#!/usr/bin/env ruby
# frozen_string_literal: true

# Usage: scripts/render-diff.rb <app-repo> <overlay> <base-ref> [<chart-dir>]
#
# Shows how a chart change alters an app repo's rendered manifests.
#   BEFORE: the app repo at <base-ref>, rendered with the chart version it pins (pulled from OCI).
#   AFTER:  the app repo at HEAD, rendered with <chart-dir> packaged locally (default: this
#           checkout's charts/syntax-workload), so a chart that is not published yet still works.
# Both renders come from scratch copies made with git archive; the app repo is never modified.
# <overlay> is the kustomize directory relative to the app repo root.

require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

KUSTOMIZE_FILES = %w[kustomization.yaml kustomization.yml Kustomization].freeze
DEFAULT_CHART = File.expand_path("../charts/syntax-workload", __dir__)

def fail!(message)
  warn "render-diff: #{message}"
  exit 1
end

# Runs a command, aborting with its stderr when it fails.
def run!(*cmd, chdir: nil, what: cmd.first)
  opts = chdir ? { chdir: chdir } : {}
  out, err, status = Open3.capture3(*cmd, **opts)
  fail!("#{what} failed (exit #{status.exitstatus})\n#{err.strip}") unless status.success?
  out
end

# Extracts <ref> of the git repo at <repo> into <dest>.
def archive(repo, ref, dest)
  FileUtils.mkdir_p(dest)
  out, err, status = Open3.capture3("git", "-C", repo, "archive", "--format=tar", ref, binmode: true)
  fail!("git archive #{ref} failed in #{repo}\n#{err}") unless status.success?
  _, err, status = Open3.capture3("tar", "-x", "-C", dest, stdin_data: out, binmode: true)
  fail!("tar extract failed\n#{err}") unless status.success?
end

def kustomization_file(dir)
  KUSTOMIZE_FILES.map { |n| File.join(dir, n) }.find { |f| File.file?(f) }
end

# Points every kustomization under root that uses helmCharts at the unpacked local chart.
def use_local_chart!(root, chart_name, chart_home)
  patched = Dir.glob(File.join(root, "**/*"), File::FNM_DOTMATCH).select do |f|
    next false unless KUSTOMIZE_FILES.include?(File.basename(f)) && File.file?(f)

    doc = YAML.safe_load(File.read(f)) || {}
    next false unless doc.is_a?(Hash) && Array(doc["helmCharts"]).any? { |c| c["name"] == chart_name }

    doc["helmGlobals"] = (doc["helmGlobals"] || {}).merge("chartHome" => chart_home)
    doc["helmCharts"].each { |c| c.delete("version") if c["name"] == chart_name && c.delete("repo") }
    File.write(f, doc.to_yaml)
    true
  end
  fail!("no kustomization under the app repo uses chart #{chart_name}") if patched.empty?
end

def render(root, overlay, label)
  dir = File.join(root, overlay)
  fail!("overlay #{overlay} has no kustomization in #{label}") unless kustomization_file(dir)

  run!("kustomize", "build", "--enable-helm", "--load-restrictor", "LoadRestrictionsNone", dir,
       what: "kustomize build (#{label})")
end

def key(obj)
  [obj["kind"], obj.dig("metadata", "namespace").to_s, obj.dig("metadata", "name")].join("/")
end

def canonical(value)
  case value
  when Hash then value.sort.to_h { |k, v| [k, canonical(v)] }
  when Array then value.map { |v| canonical(v) }
  else value
  end
end

def objects(yaml)
  YAML.load_stream(yaml).compact.to_h { |o| [key(o), canonical(o).to_yaml] }
end

def unified_diff(tmp, name, before, after)
  File.write(File.join(tmp, "before"), before)
  File.write(File.join(tmp, "after"), after)
  out, = Open3.capture2("diff", "-u", "--label", "before/#{name}", "--label", "after/#{name}",
                        "before", "after", chdir: tmp)
  out
end

fail!("usage: render-diff.rb <app-repo> <overlay> <base-ref> [<chart-dir>]") unless [3, 4].include?(ARGV.size)
app_repo, overlay, base_ref, chart_dir = ARGV
app_repo = File.expand_path(app_repo)
chart_dir = File.expand_path(chart_dir || DEFAULT_CHART)
overlay = overlay.sub(%r{\A/+}, "").chomp("/")

fail!("app repo not found: #{app_repo}") unless File.directory?(app_repo)
fail!("#{app_repo} is not a git repository") unless system("git", "-C", app_repo, "rev-parse", "--git-dir", out: File::NULL, err: File::NULL)
fail!("chart dir has no Chart.yaml: #{chart_dir}") unless File.file?(File.join(chart_dir, "Chart.yaml"))
fail!("base ref not found in app repo: #{base_ref}") unless system("git", "-C", app_repo, "rev-parse", "--verify", "--quiet", "#{base_ref}^{commit}", out: File::NULL)

chart = YAML.safe_load_file(File.join(chart_dir, "Chart.yaml"))
chart_sha = run!("git", "-C", chart_dir, "rev-parse", "--short", "HEAD", what: "git rev-parse (chart)").strip
dirty = !run!("git", "-C", chart_dir, "status", "--porcelain", "--", ".", what: "git status (chart)").strip.empty?

before_yaml = after_yaml = nil
Dir.mktmpdir("render-diff") do |tmp|
  package_dir = File.join(tmp, "package")
  FileUtils.mkdir_p(package_dir)
  run!("helm", "package", chart_dir, "--destination", package_dir, what: "helm package")
  tgz = Dir.glob(File.join(package_dir, "*.tgz")).first or fail!("helm package produced no .tgz")
  chart_home = File.join(tmp, "chart-home")
  FileUtils.mkdir_p(chart_home)
  run!("tar", "-xzf", tgz, "-C", chart_home, what: "tar (unpack chart)")
  puts "chart: #{chart['name']} #{chart['version']} @ #{chart_sha}#{' (uncommitted changes included)' if dirty}"

  before_root = File.join(tmp, "before")
  after_root = File.join(tmp, "after")
  archive(app_repo, base_ref, before_root)
  archive(app_repo, "HEAD", after_root)
  use_local_chart!(after_root, chart["name"], chart_home)

  before_yaml = render(before_root, overlay, "before (#{base_ref})")
  after_yaml = render(after_root, overlay, "after (HEAD + local chart)")
end

before = objects(before_yaml)
after = objects(after_yaml)
added = (after.keys - before.keys).sort
removed = (before.keys - after.keys).sort
common = before.keys & after.keys
modified = common.reject { |k| before[k] == after[k] }.sort

puts "app: #{app_repo} overlay: #{overlay} base: #{base_ref}"
puts "added: #{added.size}, removed: #{removed.size}, modified: #{modified.size}, unchanged: #{common.size - modified.size}"
added.each { |k| puts "+ #{k}" }
removed.each { |k| puts "- #{k}" }
modified.each { |k| puts "~ #{k}" }
Dir.mktmpdir("render-diff-cmp") do |tmp|
  modified.each do |k|
    puts
    puts unified_diff(tmp, k, before[k], after[k])
  end
end
