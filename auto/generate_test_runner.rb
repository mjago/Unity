# ==========================================
#   Unity Project - A Test Framework for C
#   Copyright (c) 2007 Mike Karlesky, Mark VanderVoord, Greg Williams
#   [Released under MIT License. Please refer to license.txt for details]
# ==========================================

$QUICK_RUBY_VERSION = RUBY_VERSION.split('.').inject(0){|vv,v| vv * 100 + v.to_i }
File.expand_path(File.join(File.dirname(__FILE__),'colour_prompt'))

class UnityTestRunnerGenerator

  def initialize(options = nil)
    @options = UnityTestRunnerGenerator.default_options
    case(options)
    when NilClass then @options
    when String   then @options.merge!(UnityTestRunnerGenerator.grab_config(options))
    when Hash     then @options.merge!(options)
    else          raise "If you specify arguments, it should be a filename or a hash of options"
    end
    require "#{File.expand_path(File.dirname(__FILE__))}/type_sanitizer"
  end

  def self.default_options
    {
      :includes         => [],
      :defines          => [],
      :plugins          => [],
      :framework        => :unity,
      :test_prefix      => "test|spec|should",
      :setup_name       => "setUp",
      :teardown_name    => "tearDown",
      :main_name        => "main", #set to :auto to automatically generate each time
      :main_export_decl => "",
      :cmdline_args     => false,
      :use_param_tests  => false,
    }
  end

  def self.grab_config(config_file)
    options = self.default_options
    unless (config_file.nil? or config_file.empty?)
      require 'yaml'
      yaml_guts = YAML.load_file(config_file)
      options.merge!(yaml_guts[:unity] || yaml_guts[:cmock])
      raise "No :unity or :cmock section found in #{config_file}" unless options
    end
    return(options)
  end

  def run(input_file, output_file, options=nil)
    tests = []
    testfile_includes = []
    used_mocks = []

    @options.merge!(options) unless options.nil?
    module_name = File.basename(input_file)

    # pull required data from source file
    source = File.read(input_file)
    source = source.force_encoding("ISO-8859-1").encode("utf-8", :replace => nil) if ($QUICK_RUBY_VERSION > 10900)
    tests               = find_tests(source)
    headers             = find_includes(source)
    testfile_includes   = (headers[:local] + headers[:system])
    used_mocks          = find_mocks(testfile_includes)
    testfile_includes   = (testfile_includes - used_mocks)
    testfile_includes.delete_if{|inc| inc =~ /(unity|cmock)/}

    # build runner file
    generate(input_file, output_file, tests, used_mocks, testfile_includes)

    # determine which files were used to return them
    all_files_used = [input_file, output_file]
    all_files_used += testfile_includes.map {|filename| filename + '.c'} unless testfile_includes.empty?
    all_files_used += @options[:includes] unless @options[:includes].empty?
    return all_files_used.uniq
  end

  def generate(input_file, output_file, tests, used_mocks, testfile_includes)
    out = []
    out << create_header(used_mocks, testfile_includes)
    out << create_externs(tests, used_mocks)
    out << create_mock_management(used_mocks)
    out << create_suite_setup_and_teardown
    out << create_reset(used_mocks)
    out << create_main(input_file, tests, used_mocks)
    File.open(output_file, 'w') do |f|
      f.write(out.join("\n"))
    end

    if (@options[:header_file] && !@options[:header_file].empty?)
      File.open(@options[:header_file], 'w') do |f|
        f.write(create_h_file(@options[:header_file], tests, testfile_includes, used_mocks))
      end
    end
  end

  def find_tests(source)
    tests_and_line_numbers = []
    source_scrubbed = source.clone
    source_scrubbed = source_scrubbed.gsub(/"[^"\n]*"/, '')      # remove things in strings
    source_scrubbed = source_scrubbed.gsub(/\/\/.*$/, '')      # remove line comments
    source_scrubbed = source_scrubbed.gsub(/\/\*.*?\*\//m, '') # remove block comments
    lines = source_scrubbed.split(/(^\s*\#.*$)                 # Treat preprocessor directives as a logical line
                              | (;|\{|\}) /x)                  # Match ;, {, and } as end of lines

    lines.each_with_index do |line, index|
      # find tests
      if line =~ /^((?:\s*TEST_CASE\s*\(.*?\)\s*)*)\s*void\s+((?:#{@options[:test_prefix]}).*)\s*\(\s*(.*)\s*\)/
        arguments = $1
        name = $2
        call = $3
        params = $4
        args = nil
        if (@options[:use_param_tests] and !arguments.empty?)
          args = []
          arguments.scan(/\s*TEST_CASE\s*\((.*)\)\s*$/) {|a| args << a[0]}
        end
        tests_and_line_numbers << { :test => name, :args => args, :call => call, :params => params, :line_number => 0 }
      end
    end
    tests_and_line_numbers.uniq! {|v| v[:test] }

    # determine line numbers and create tests to run
    source_lines = source.split("\n")
    source_index = 0;
    tests_and_line_numbers.size.times do |i|
      source_lines[source_index..-1].each_with_index do |line, index|
        if (line =~ /#{tests_and_line_numbers[i][:test]}/)
          source_index += index
          tests_and_line_numbers[i][:line_number] = source_index + 1
          break
        end
      end
    end

    return tests_and_line_numbers
  end

  def find_includes(source)

    # remove comments (block and line, in three steps to ensure correct precedence)
    source.gsub!(/\/\/(?:.+\/\*|\*(?:$|[^\/])).*$/, '')  # remove line comments that comment out the start of blocks
    source.gsub!(/\/\*.*?\*\//m, '')                     # remove block comments
    source.gsub!(/\/\/.*$/, '')                          # remove line comments (all that remain)

    # parse out includes
    includes = {
      :local => source.scan(/^\s*#include\s+\"\s*(.+)\.[hH]\s*\"/).flatten,
      :system => source.scan(/^\s*#include\s+<\s*(.+)\s*>/).flatten.map { |inc| "<#{inc}>" }
    }
    return includes
  end

  def find_mocks(includes)
    mock_headers = []
    includes.each do |include_path|
      include_file = File.basename(include_path)
      mock_headers << include_path if (include_file =~ /^mock/i)
    end
    return mock_headers
  end

  def create_header(mocks, testfile_includes=[])
    out = []
    out << '/* AUTOGENERATED FILE. DO NOT EDIT. */'
    out << create_runtest(mocks)
    out << "\n/*=======Automagically Detected Files To Include=====*/"
    out << "#include \"#{@options[:framework]}.h\""
    out << '#include "cmock.h"' unless (mocks.empty?)
    out << '#include <setjmp.h>'
    out << '#include <stdio.h>'
    out << '#include "CException.h"' if @options[:plugins].include?(:cexception)
    if (@options[:defines] && !@options[:defines].empty?)
      @options[:defines].each {|d| output.puts("#define #{d}")}
    end
    if (@options[:header_file] && !@options[:header_file].empty?)
      out << "#include \"#{File.basename(@options[:header_file])}\""
    else
      @options[:includes].flatten.uniq.compact.each do |inc|
        out << "#include #{inc.include?('<') ? inc : "\"#{inc.gsub('.h','')}.h\""}"
      end
      testfile_includes.each do |inc|
      out << "#include #{inc.include?('<') ? inc : "\"#{inc.gsub('.h','')}.h\""}"
      end
    end
    mocks.each do |mock|
      out << "#include \"#{mock.gsub('.h','')}.h\""
    end
    if @options[:enforce_strict_ordering]
      out << ''
      out << 'int GlobalExpectCount;'
      out << 'int GlobalVerifyOrder;'
      out << 'char* GlobalOrderError;'
    end
    out.join("\n")
  end

  def create_externs(tests, mocks)
    out = []
    out << "\n/*=======External Functions This Runner Calls=====*/"
    out << "extern void #{@options[:setup_name]}(void);"
    out << "extern void #{@options[:teardown_name]}(void);"
    tests.each do |test|
      out << "extern void #{test[:test]}(#{test[:call] || 'void'});"
    end
    out.join("\n")
  end

  def create_mock_management(mock_headers)
    out = []
    unless (mock_headers.empty?)
      out << "\n/*=======Mock Management=====*/"
      out << 'static void CMock_Init(void)'
      out << '{'
      if @options[:enforce_strict_ordering]
        out << '  GlobalExpectCount = 0;'
        out << '  GlobalVerifyOrder = 0;'
        out << '  GlobalOrderError = NULL;'
      end
      mocks = mock_headers.map { |mock| File.basename(mock) }
      mocks.each do |mock|
        mock_clean = TypeSanitizer.sanitize_c_identifier(mock)
        out << "  #{mock_clean}_Init();"
      end
      out << "}\n"
      out << 'static void CMock_Verify(void)'
      out << '{'
      mocks.each do |mock|
        mock_clean = TypeSanitizer.sanitize_c_identifier(mock)
        out << "  #{mock_clean}_Verify();"
      end
      out << "}\n"

      out << "static void CMock_Destroy(void)"
      out << '{'
      mocks.each do |mock|
        mock_clean = TypeSanitizer.sanitize_c_identifier(mock)
        out << "  #{mock_clean}_Destroy();"
      end
      out << "}\n"
    end
    out.join("\n")
  end

  def create_suite_setup_and_teardown
    out = []
    unless (@options[:suite_setup].nil?)
      out << "\n/*=======Suite Setup=====*/"
      out << 'static void suite_setup(void)'
      out << '{'
      out << @options[:suite_setup]
      out << '}'
    end
    unless @options[:suite_teardown].nil?
      out << "\n/*=======Suite Teardown=====*/"
      out << 'static int suite_teardown(int num_failures)'
      out << '{'
      out << @options[:suite_teardown]
      out << '}'
    end
    out.join("\n")
  end

  def create_runtest(used_mocks)
    cexception = @options[:plugins].include? :cexception
    va_args1   = @options[:use_param_tests] ? ', ...' : ''
    va_args2   = @options[:use_param_tests] ? '__VA_ARGS__' : ''
    out = []
    out << "\n/*=======Test Runner Used To Run Each Test Below=====*/"
    out << '#define RUN_TEST_NO_ARGS' if @options[:use_param_tests]
    out << "#define RUN_TEST(TestFunc, TestLineNum#{va_args1}) \\"
    out << '{ \\'
    out << "  Unity.CurrentTestName = #TestFunc#{va_args2.empty? ? '' : " \"(\" ##{va_args2} \")\""}; \\"
        out << '  Unity.CurrentTestLineNumber = TestLineNum; \\'
    out << '  if (UnityTestMatches()) { \\' if (@options[:cmdline_args])
    out << '  Unity.NumberOfTests++; \\'
    out << '  CMock_Init(); \\' unless (used_mocks.empty?)
    out << '  UNITY_CLR_DETAILS(); \\' unless (used_mocks.empty?)
    out << '  if (TEST_PROTECT()) \\'
    out << '  { \\'
    out << '    CEXCEPTION_T e; \\' if cexception
    out << '    Try { \\' if cexception
    out << "      #{@options[:setup_name]}(); \\"
    out << "      TestFunc(#{va_args2}); \\"
    out << '    } Catch(e) { TEST_ASSERT_EQUAL_HEX32_MESSAGE(CEXCEPTION_NONE, e, "Unhandled Exception!"); } \\' if cexception
    out << '  } \\'
    out << '  if (TEST_PROTECT() && !TEST_IS_IGNORED) \\'
    out << '  { \\'
    out << "    #{@options[:teardown_name]}(); \\"
    out << '    CMock_Verify(); \\' unless (used_mocks.empty?)
    out << '  } \\'
    out << '  CMock_Destroy(); \\' unless (used_mocks.empty?)
    out << '  UnityConcludeTest(); \\'
    out << '  } \\' if (@options[:cmdline_args])
    out << '}'
    out.join("\n")
  end

  def create_reset(used_mocks)
    out = []
    out << "/*=======Test Reset Option=====*/"
    out << 'void resetTest(void);'
    out << 'void resetTest(void)'
    out << '{'
    out << '  CMock_Verify(); ' unless used_mocks.empty?
    out << '  CMock_Destroy();' unless used_mocks.empty?
    out << "  #{@options[:teardown_name]}();"
    out << '  CMock_Init();' unless used_mocks.empty?
    out << "  #{@options[:setup_name]}();"
    out << '}'
    out.join("\n")
  end

  def create_main(filename, tests, used_mocks)
    out = []
    out << "\n\n/*=======MAIN=====*/"
    main_name = (@options[:main_name].to_sym == :auto) ? "main_#{filename.gsub('.c','')}" : "#{@options[:main_name]}"
    if (@options[:cmdline_args])
      out << "#{@options[:main_export_decl]} int #{main_name}(int argc, char** argv);" if (main_name != "main")
      out << " #{@options[:main_export_decl]} int #{main_name}(int argc, char** argv)"
      out << ' {'
      out << '   int parse_status = UnityParseOptions(argc, argv);'
      out << '   if (parse_status != 0)'
      out << '   {'
      out << '     if (parse_status < 0)'
      out << '     {'
      out << '       UnityPrint("' + "#{filename.gsub('.c','')}" + '.");'
      out << '       UNITY_PRINT_EOL();'

      if (@options[:use_param_tests])
        tests.each do |test|
          if ((test[:args].nil?) or (test[:args].empty?))
            out << "      UnityPrint(\"  #{test[:test]}(RUN_TEST_NO_ARGS)\");"
            out << '      UNITY_PRINT_EOL();'
          else
            test[:args].each do |args|
              out << "      UnityPrint(\"  #{test[:test]}(#{args})\");"
              out << '      UNITY_PRINT_EOL();'
            end
          end
        end
      else
        tests.each { |test| out << "      UnityPrint(\"  #{test[:test]}\");\n    UNITY_PRINT_EOL();" }
      end
      out << '    return 0;'
      out << '    }'
      out << '  return parse_status;'
      out << '  }'
    else
      if (main_name != "main")
        out << "#{@options[:main_export_decl]} int #{main_name}(void);"
      end
      out << "int #{main_name}(void)"
      out << '{'
    end
    out << '  suite_setup();' unless @options[:suite_setup].nil?
    out << "  UnityBegin(\"#{filename.gsub(/\\/,'\\\\\\')}\");"
    if (@options[:use_param_tests])
      tests.each do |test|
        if ((test[:args].nil?) or (test[:args].empty?))
          out << "  RUN_TEST(#{test[:test]}, #{test[:line_number]}, RUN_TEST_NO_ARGS);"
        else
          test[:args].each { |args| out << "  RUN_TEST(#{test[:test]}, #{test[:line_number]}, #{args});" }
        end
      end
    else
      tests.each { |test| out << "  RUN_TEST(#{test[:test]}, #{test[:line_number]});" }
    end
    out << ''
    out << '  CMock_Guts_MemFreeFinal();' unless used_mocks.empty?
    out << "  return #{@options[:suite_teardown].nil? ? "" : "suite_teardown"}(UnityEnd());"
    out << "}\n"
    out.join("\n")
  end

  def create_h_file(filename, tests, testfile_includes, used_mocks)
    filename = File.basename(filename).gsub(/[-\/\\\.\,\s]/, "_").upcase
    out = []
    out << '/* AUTOGENERATED FILE. DO NOT EDIT. */'
    out << "#ifndef _#{filename}"
    out << "#define _#{filename}\n\n"
    out << "#include \"#{@options[:framework]}.h\""
    out << '#include "cmock.h"' unless used_mocks.empty?
    @options[:includes].flatten.uniq.compact.each do |inc|
      out << "#include #{inc.include?('<') ? inc : "\"#{inc.gsub('.h','')}.h\""}"
    end
    testfile_includes.each do |inc|
    out << "#include #{inc.include?('<') ? inc : "\"#{inc.gsub('.h','')}.h\""}"
    end
    out << ''
    tests.each do |test|
      if((test[:params].nil?) or (test[:params].empty?))
        out << "void #{test[:test]}(void);"
      else
        out << "void #{test[:test]}(#{test[:params]});"
      end
    end
    out << "#endif\n\n"
    out.join("\n")
  end
end

if ($0 == __FILE__)
  options = { :includes => [] }

  # parse out all the options first (these will all be removed as we go)
  ARGV.reject! do |arg|
    case(arg)
    when '-cexception'
      options[:plugins] = [:cexception]; true
    when /\.*\.ya?ml/
      options = UnityTestRunnerGenerator.grab_config(arg); true
    when /--(\w+)=\"?(.*)\"?/
      options[$1.to_sym] = $2; true
    when /\.*\.h/
      options[:includes] << arg; true
    else false
    end
  end

  HelpText = %Q(
usage: ruby #{__FILE__} (files) (options) input_test_file (output)

  input_test_file         - this is the C file you want to create a runner for
  output                  - this is the name of the runner file to generate
                            defaults to (input_test_file)_Runner
  files:
    *.yml / *.yaml        - loads configuration from here in :unity or :cmock
    *.h                   - header files are added as #includes in runner
  options:
    -cexception           - include cexception support
    --setup_name=""       - redefine setUp func name to something else
    --teardown_name=""    - redefine tearDown func name to something else
    --main_name=""        - redefine main func name to something else
    --test_prefix=""      - redefine test prefix from default test|spec|should
    --suite_setup=""      - code to execute for setup of entire suite
    --suite_teardown=""   - code to execute for teardown of entire suite
    --use_param_tests=1   - enable parameterized tests (disabled by default)
    --header_file=""      - path/name of test header file to generate too)

  # make sure there is at least one parameter left (the input file)
  puts HelpText unless ARGV[0]
  exit(1) unless ARGV[0]

  # create the default test runner name if not specified
  ARGV[1] = ARGV[0].gsub('.c','_Runner.c') unless ARGV[1]

  UnityTestRunnerGenerator.new(options).run(ARGV[0], ARGV[1])
end
