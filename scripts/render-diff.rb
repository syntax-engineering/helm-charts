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

class RenderError < StandardError; end

# A local chart directory: packaged to a tgz and unpacked so kustomize can use it as chartHome.
class Chart
  attr_reader :dir, :name, :version

  def initialize(dir)
    @dir = dir
    raise RenderError, "chart dir has no Chart.yaml: #{dir}" unless File.file?(File.join(dir, "Chart.yaml"))

    meta = YAML.safe_load_file(File.join(dir, "Chart.yaml"))
    @name = meta["name"]
    @version = meta["version"]
  end

  def sha
    @sha ||= run!("git", "-C", dir, "rev-parse", "--short", "HEAD", what: "git rev-parse (chart)").strip
  end

  def dirty?
    !run!("git", "-C", dir, "status", "--porcelain", "--", ".", what: "git status (chart)").strip.empty?
  end

  def describe
    "#{name} #{version} @ #{sha}#{' (uncommitted changes included)' if dirty?}"
  end

  # Packages the chart under <tmp> and returns the directory holding the unpacked chart.
  def unpack(tmp)
    package_dir = File.join(tmp, "package")
    FileUtils.mkdir_p(package_dir)
    run!("helm", "package", dir, "--destination", package_dir, what: "helm package")
    tgz = Dir.glob(File.join(package_dir, "*.tgz")).first or raise RenderError, "helm package produced no .tgz"
    home = File.join(tmp, "chart-home")
    FileUtils.mkdir_p(home)
    run!("tar", "-xzf", tgz, "-C", home, what: "tar (unpack chart)")
    home
  end
end

# The app git repo; never modified, only read through git archive.
class AppRepo
  attr_reader :path

  def initialize(path)
    @path = File.expand_path(path)
    raise RenderError, "app repo not found: #{@path}" unless File.directory?(@path)
    raise RenderError, "#{@path} is not a git repository" unless git_ok?("-C", @path, "rev-parse", "--git-dir")
  end

  def ref?(ref)
    git_ok?("-C", path, "rev-parse", "--verify", "--quiet", "#{ref}^{commit}")
  end

  # Extracts <ref> into <dest>.
  def archive(ref, dest)
    FileUtils.mkdir_p(dest)
    out, err, status = Open3.capture3("git", "-C", path, "archive", "--format=tar", ref, binmode: true)
    raise RenderError, "git archive #{ref} failed in #{path}\n#{err}" unless status.success?

    _, err, status = Open3.capture3("tar", "-x", "-C", dest, stdin_data: out, binmode: true)
    raise RenderError, "tar extract failed\n#{err}" unless status.success?
  end
end

# One kustomize build of an overlay in an extracted copy of the app repo.
class Render
  def initialize(root, overlay, label)
    @root = root
    @overlay = overlay
    @label = label
  end

  # Points every kustomization that uses the chart at the unpacked local chart.
  def use_local_chart(chart_name, chart_home)
    patched = Dir.glob(File.join(@root, "**/*"), File::FNM_DOTMATCH).select do |f|
      next false unless KUSTOMIZE_FILES.include?(File.basename(f)) && File.file?(f)

      doc = YAML.safe_load(File.read(f)) || {}
      next false unless doc.is_a?(Hash) && Array(doc["helmCharts"]).any? { |c| c["name"] == chart_name }

      doc["helmGlobals"] = (doc["helmGlobals"] || {}).merge("chartHome" => chart_home)
      doc["helmCharts"].each { |c| c.delete("version") if c["name"] == chart_name && c.delete("repo") }
      File.write(f, doc.to_yaml)
      true
    end
    raise RenderError, "no kustomization under the app repo uses chart #{chart_name}" if patched.empty?
  end

  # Builds the overlay and returns { "Kind/namespace/name" => canonical YAML text }.
  def objects
    dir = File.join(@root, @overlay)
    unless KUSTOMIZE_FILES.any? { |n| File.file?(File.join(dir, n)) }
      raise RenderError, "overlay #{@overlay} has no kustomization in #{@label}"
    end

    yaml = run!("kustomize", "build", "--enable-helm", "--load-restrictor", "LoadRestrictionsNone", dir,
                what: "kustomize build (#{@label})")
    YAML.load_stream(yaml).compact.to_h { |o| [key(o), canonical(o).to_yaml] }
  end

  private

  def key(obj)
    [obj["kind"], obj.dig("metadata", "namespace").to_s, obj.dig("metadata", "name")].join("/")
  end

  # Sorts hash keys recursively so two equal resources dump to identical text.
  def canonical(value)
    case value
    when Hash then value.sort.to_h { |k, v| [k, canonical(v)] }
    when Array then value.map { |v| canonical(v) }
    else value
    end
  end
end

# Comparison of two renders' objects.
class Diff
  attr_reader :added, :removed, :modified, :unchanged

  def initialize(before, after)
    @before = before
    @after = after
    @added = (after.keys - before.keys).sort
    @removed = (before.keys - after.keys).sort
    common = before.keys & after.keys
    @modified = common.reject { |k| before[k] == after[k] }.sort
    @unchanged = common.size - @modified.size
  end

  def unified(key, tmp)
    File.write(File.join(tmp, "before"), @before[key])
    File.write(File.join(tmp, "after"), @after[key])
    out, = Open3.capture2("diff", "-u", "--label", "before/#{key}", "--label", "after/#{key}",
                          "before", "after", chdir: tmp)
    out
  end
end

class Report
  def initialize(diff, app_repo:, overlay:, base_ref:)
    @diff = diff
    @header = "app: #{app_repo.path} overlay: #{overlay} base: #{base_ref}"
  end

  def print
    puts @header
    puts "added: #{@diff.added.size}, removed: #{@diff.removed.size}, modified: #{@diff.modified.size}, " \
         "unchanged: #{@diff.unchanged}"
    @diff.added.each { |k| puts "+ #{k}" }
    @diff.removed.each { |k| puts "- #{k}" }
    @diff.modified.each { |k| puts "~ #{k}" }
    Dir.mktmpdir("render-diff-cmp") do |tmp|
      @diff.modified.each do |k|
        puts
        puts @diff.unified(k, tmp)
      end
    end
  end
end

# Runs a command, raising RenderError with its stderr when it fails.
def run!(*cmd, chdir: nil, what: cmd.first)
  opts = chdir ? { chdir: chdir } : {}
  out, err, status = Open3.capture3(*cmd, **opts)
  raise RenderError, "#{what} failed (exit #{status.exitstatus})\n#{err.strip}" unless status.success?

  out
end

def git_ok?(*args)
  system("git", *args, out: File::NULL, err: File::NULL)
end

def main(argv)
  raise RenderError, "usage: render-diff.rb <app-repo> <overlay> <base-ref> [<chart-dir>]" unless [3, 4].include?(argv.size)

  app_path, overlay, base_ref, chart_dir = argv
  overlay = overlay.sub(%r{\A/+}, "").chomp("/")
  app_repo = AppRepo.new(app_path)
  chart = Chart.new(File.expand_path(chart_dir || DEFAULT_CHART))
  raise RenderError, "base ref not found in app repo: #{base_ref}" unless app_repo.ref?(base_ref)

  before = after = nil
  Dir.mktmpdir("render-diff") do |tmp|
    description = chart.describe
    chart_home = chart.unpack(tmp)
    puts "chart: #{description}"

    before_root = File.join(tmp, "before")
    after_root = File.join(tmp, "after")
    app_repo.archive(base_ref, before_root)
    app_repo.archive("HEAD", after_root)
    after_render = Render.new(after_root, overlay, "after (HEAD + local chart)")
    after_render.use_local_chart(chart.name, chart_home)

    before = Render.new(before_root, overlay, "before (#{base_ref})").objects
    after = after_render.objects
  end

  Report.new(Diff.new(before, after), app_repo: app_repo, overlay: overlay, base_ref: base_ref).print
rescue RenderError => e
  warn "render-diff: #{e.message}"
  exit 1
end

main(ARGV)
