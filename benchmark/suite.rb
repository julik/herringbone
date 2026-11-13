# frozen_string_literal: true

require_relative "../lib/herringbone"
require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "tmpdir"
require_relative "suite/corpus"

module BenchmarkSuite
  ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.expand_path(__FILE__)
  CASES = %w[write_typed write_coercible read replace_rows replace_column delete same union intersection].freeze

  @implementations = {}

  def self.cli(argv)
    options = {}
    parser = OptionParser.new do |option|
      option.banner = "Usage: ruby benchmark/suite.rb [options]"
      option.on("--long", "1M rows, five repetitions, no time cap") { options[:config] = Corpus::LONG }
      option.on("--corpus DIR", "Generate or reuse a compatible corpus") { |path| options[:corpus] = path }
      option.on("--output DIR", "New/empty result directory (default: unique temporary directory)") do |path|
        options[:output] = path
      end
      option.on("--implementation-file FILE", "Trusted Ruby file registering comparison implementations") do |path|
        options[:implementation_file] = path
      end
      option.on("-h", "--help", "Show help") do
        puts option
        return 0
      end
    end
    parser.parse!(argv)
    raise OptionParser::InvalidArgument, argv.join(" ") unless argv.empty?

    Runner.new(**options).run ? 0 : 1
  end

  def self.worker(job)
    Worker.new(job, @implementations).run
  end

  def self.register_implementation(name, &setup)
    name = name.to_s
    if name.strip.empty? || name == "ruby" || @implementations.key?(name) || !setup
      raise ArgumentError, "implementation needs a unique nonempty name and setup block"
    end
    @implementations[name] = setup
  end

  def self.sources(implementation_file = nil)
    implementation = if implementation_file && File.file?(implementation_file)
      Digest::SHA256.file(implementation_file).hexdigest
    end

    {
      "library" => source_digest(Dir[File.join(ROOT, "lib/**/*.rb")]),
      "harness" => source_digest([SCRIPT, *Dir[File.join(__dir__, "suite/**/*.rb")]]),
      "implementation" => implementation
    }
  end

  def self.backend(original_decoder = decoder_methods)
    selected = Herringbone::Codecs::Snappy.backend.to_s
    {
      "snappy" => selected,
      "io_buffer_available" => Herringbone::IOBufferSupport::AVAILABLE,
      "ruby_buffer" => decoder_buffer(selected, original_decoder),
      "ruby" => RUBY_DESCRIPTION,
      "herringbone" => Herringbone::VERSION,
      "jit" => jit_state
    }
  end

  def self.source_digest(paths)
    files = paths.sort.to_h do |path|
      [path.delete_prefix("#{ROOT}/"), Digest::SHA256.file(path).hexdigest]
    end
    Digest::SHA256.hexdigest(JSON.generate(files))
  end

  def self.decoder_methods
    %i[decompress decompress_io_buffer decompress_string native native_library].map do |name|
      Herringbone::Codecs::Snappy.method(name)
    end
  end

  def self.decoder_buffer(selected, original_decoder)
    return "unknown" unless original_decoder == decoder_methods
    return nil unless selected == "ruby"

    Herringbone::IOBufferSupport::AVAILABLE ? "io_buffer" : "string"
  end

  def self.jit_state
    RubyVM.constants.grep(/JIT/).to_h do |name|
      jit = RubyVM.const_get(name)
      [name.to_s, jit.respond_to?(:enabled?) && jit.enabled?]
    end
  end
end

require_relative "suite/worker"
require_relative "suite/runner"

if $PROGRAM_NAME == __FILE__
  begin
    if ARGV.first == "__worker"
      BenchmarkSuite.worker(JSON.parse(ARGV.fetch(1)))
    else
      exit BenchmarkSuite.cli(ARGV)
    end
  rescue => error
    warn "#{error.class}: #{error.message}\n#{error.backtrace.first(8).join("\n")}"
    exit 1
  end
end
