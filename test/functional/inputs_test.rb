require "functional/helper"
require "tempfile"

# For tests related to reading inputs from plugins, see plugins_test.rb

describe "inputs" do
  include FunctionalHelper
  let(:inputs_profiles_path) { File.join(profile_path, "inputs") }

  # This tests being able to load complex structures from
  # cli option-specified files.
  %w{
    flat
    nested
  }.each do |input_file|
    it "runs OK on #{input_file} inputs" do
      cmd = "exec "
      cmd += File.join(inputs_profiles_path, "basic")
      cmd += " --no-create-lockfile"
      cmd += " --input-file " + File.join(inputs_profiles_path, "basic", "files", "#{input_file}.yaml")
      cmd += " --controls " + input_file

      result = run_inspec_process(cmd)

      result.stderr.must_equal ""
      assert_exit_code 0, result
    end
  end

  describe "when asking for usage help" do
    it "includes the new --input-file option" do
      result = run_inspec_process("exec help", lock: true) # --no-create-lockfile option breaks usage help

      lines = result.stdout.split("\n")
      line = lines.detect { |l| l.include? "--input-file" }
      line.wont_be_nil
    end

    it "includes the legacy --attrs option" do
      result = run_inspec_process("exec help", lock: true)

      lines = result.stdout.split("\n")
      line = lines.detect { |l| l.include? "--attrs" }
      line.wont_be_nil
    end
  end

  describe "when using a cli-specified file" do
    let(:result) do
      cmd =  "exec "
      cmd += File.join(inputs_profiles_path, "basic") + " "
      cmd += flag + " " + File.join(inputs_profiles_path, "basic", "files", "flat.yaml")
      cmd += " --controls flat"

      run_inspec_process(cmd)
    end
    describe "when the --input-file flag is used" do
      let(:flag) { "--input-file" }
      it "works" do
        assert_exit_code 0, result
      end
    end
    describe "when the --attrs flag is used" do
      let(:flag) { "--attrs" }
      it "works" do
        assert_exit_code 0, result
      end
    end
  end

  describe "when being passed inputs via the Runner API" do
    let(:run_result) { run_runner_api_process(runner_options) }
    let(:common_options) do
      {
        profile: "#{inputs_profiles_path}/via-runner",
        reporter: ["json"],
      }
    end

    # options:
    #   profile: path to profile to run
    #   All other opts passed to InSpec::Runner.new(...)
    # then add.target is called
    def run_runner_api_process(options)
      # Remove profile from options. All other are passed to Runner.
      profile = options.delete(:profile)

      # Make a tmpfile
      Tempfile.open(mode: 0700) do |script| # 0700 - rwx

        # include ruby path
        # script.puts %q[ # Load path ]

        # Clear and concat - can't just assign, it's readonly
        script.puts "$LOAD_PATH.clear"
        script.puts "$LOAD_PATH.concat(#{$LOAD_PATH})"
        script.puts

        # require inspec
        script.puts %q{ require "inspec" }
        script.puts %q{ require "inspec/runner" }
        script.puts

        # inject pretty-printed runner opts
        script.puts %q{ # Arguments for runner: }
        script.write %q{ runner_args = }
        script.puts options.inspect
        script.puts

        # inject target
        script.puts %q{ # Profile to run: }
        script.puts " profile_location = \"#{profile}\""
        script.puts

        # create runner with opts
        script.puts %q{ # Run Execution }
        script.puts %q{ runner = Inspec::Runner.new(runner_args) }
        script.puts %q{ runner.add_target profile_location }
        script.puts %q{ runner.run }

        script.flush

        train_cxn = Train.create("local", command_runner: :generic).connection
        # TODO - portability - this does not have windows compat stuff from the inspec() method in functional/helper.rb
        # it is not portable to windows at this point yet.
        train_cxn.run_command("ruby #{script.path}") # TODO get path to file

      end
    end

    describe "when using the current :inputs key" do
      let(:runner_options) { common_options.merge({ inputs: { test_input_01: "value_from_api" } }) }

      it "finds the values and does not issue any warnings" do
        output = run_result.stdout
        refute_includes output, "DEPRECATION"
        structured_output = JSON.parse(output)
        assert_equal "passed", structured_output["profiles"][0]["controls"][0]["results"][0]["status"]
      end
    end

    describe "when using the legacy :attributes key" do
      let(:runner_options) { common_options.merge({ attributes: { test_input_01: "value_from_api" } }) }
      it "finds the values but issues a DEPRECATION warning" do
        output = run_result.stdout
        assert_includes output, "DEPRECATION"
        structured_output = JSON.parse(output.lines.reject { |l| l.include? "DEPRECATION" }.join("\n") )
        assert_equal "passed", structured_output["profiles"][0]["controls"][0]["results"][0]["status"]
      end
    end
  end

  describe "when accessing inputs in a variety of scopes using the DSL" do
    it "is able to read the inputs using the input keyword" do
      cmd = "exec #{inputs_profiles_path}/scoping"

      result = run_inspec_process(cmd, json: true)

      result.must_have_all_controls_passing
    end
    it "is able to read the inputs using the legacy attribute keyword" do
      cmd = "exec #{inputs_profiles_path}/legacy-attributes-dsl"

      result = run_inspec_process(cmd, json: true)

      result.must_have_all_controls_passing
    end
  end

  describe "run profile with metadata inputs" do

    it "works when using the new 'inputs' key" do
      cmd = "exec #{inputs_profiles_path}/metadata-basic"

      result = run_inspec_process(cmd, json: true)

      result.must_have_all_controls_passing
      result.stderr.must_be_empty
    end

    it "works when using the legacy 'attributes' key" do
      cmd = "exec #{inputs_profiles_path}/metadata-legacy"

      result = run_inspec_process(cmd, json: true)

      result.must_have_all_controls_passing
      # Will eventually issue deprecation warning
    end

    it "does not error when inputs are empty" do
      cmd = "exec "
      cmd += File.join(inputs_profiles_path, "metadata-empty")

      result = run_inspec_process(cmd, json: true)

      result.stderr.must_include "WARN: Inputs must be defined as an Array in metadata files. Skipping definition from profile-with-empty-attributes."
      assert_exit_code 0, result
    end

    it "errors with invalid input types" do
      cmd = "exec "
      cmd += File.join(inputs_profiles_path, "metadata-invalid")

      result = run_inspec_process(cmd, json: true)

      result.stderr.must_equal "Type 'Color' is not a valid input type.\n"
      assert_exit_code 1, result
    end

    it "errors with required input not defined" do
      cmd = "exec "
      cmd += File.join(inputs_profiles_path, "metadata-required")

      result = run_inspec_process(cmd, json: true)

      result.stderr.must_include "Input 'a_required_input' is required and does not have a value.\n"
      assert_exit_code 1, result
    end

    describe "when profile inheritance is used" do
      it "should correctly assign input values using namespacing" do
        cmd = "exec " + File.join(inputs_profiles_path, "inheritance", "wrapper")

        result = run_inspec_process(cmd, json: true)

        result.must_have_all_controls_passing
      end
    end
  end

  describe "when using a profile with undeclared (valueless) inputs" do
    it "should warn about them and not abort the run" do
      cmd = "exec #{inputs_profiles_path}/undeclared"

      result = run_inspec_process(cmd, json: true)

      result.stderr.must_include "WARN: Input 'undeclared_01'"
      result.stderr.must_include "does not have a value"
      result.must_have_all_controls_passing
    end
  end
end
