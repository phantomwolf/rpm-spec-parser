#!/usr/bin/env ruby
require 'json'
require 'optparse'

class InvalidSpecError < StandardError
  def initialize(msg)
    @msg = msg
  end

  def message
    return @msg
  end
end


class RpmSpecParser
  attr_reader :sections, :path

  SECTIONS            = ['%build', '%description', '%files', '%package',
                        '%install', '%prep', '%changelog', '%clean', '%check',
                        '%pre', '%post', '%preun', '%postun', '%verifyscript']

  CONDITIONAL_MACROS  = ['%if', '%else', '%endif']

  # Initialize the parser with a spec file
  # Params:
  #   spec_file - path of the spec file
  def initialize(spec_file)
    unless File.exists?(spec_file)
      raise InvalidSpecError.new("#{spec_file}: No such file")
    end
    @path   = spec_file
    @macros = {}
    @vars   = {}
    @tags   = {}
  end

  # Detect macro type
  # Params:
  #   macro - Name of the macro, including the '%' character
  # Return:
  #   :conditional  - %if, %ifarch, %ifos, %else, %endif, etc
  #   :section      - %build, %prep, %files, etc
  #   nil           - considered as normal lines
  def macro_type(macro)
    # Conditional macros are ignored
    CONDITIONAL_MACROS.each do |pattern|
      return :conditional if macro.start_with?(pattern)
    end
    # Multi-line macros
    SECTIONS.each do |pattern|
      return :section if macro == pattern
    end
    # Other macros like %setup, %dir
    # will be considered as normal lines
    return nil
  end

  # Read and split spec file into sections
  # Each section starts with a section line, such as '%package doc', '%build'
  def read_sections
    @sections = {}
    begin
      f = File.new(@path)
    rescue IOError => e
      raise IOError.new("Failed to read #{@path}")
    end
    section = ['%package'] # fake section for the main package
    package_name = 'main'
    f.each_line do |line|
      line = line.strip
      # Skip empty lines and comments
      next if line.length == 0 or line.start_with?('#')
      # Handle section lines(e.g. %package doc)
      section_name, args = line.start_with?('%') ? self.get_section_and_args(line) : [nil, nil]
      if section_name.nil? or self.macro_type(section_name) != :section
        section.push(line)
      else
        # Save the previous section
        @sections[package_name] = {} if @sections[package_name].nil?
        @sections[package_name][section_name] = section.join("\n")
        # Parse the section
        self.parse_section(@sections[package_name][section_name])
        # Create a new section
        section = [line]
      end
    end
    # Save the last section
    @sections[package_name] = {} if @sections[package_name].nil?
    @sections[package_name][section_name] = section.join("\n")
    # Parse the section
    self.parse_section(@sections[package_name][section_name])
    # Close the file
    f.close
  end

  # Get tag value
  # Params:
  #   package - Name of the package. For default package, it should be 'main'
  #   tag     - Tag name, e.g. Name, Version, Release, Requires
  def get_tag_value(package, tag)
    package = self.get_macro_value('name') if package.nil? or package == ''
    return nil if @tags[package].nil?
    return @tags[package][tag]
  end

  # Set tag value
  # Params:
  #   package - Name of the package. For default package, it should be 'main'
  #   tag     - Tag name, e.g. Name, Version, Release, Requires
  #   value   - Value of the tag
  def set_tag_value(package, tag, value)
    @tags[package] = {} if @tags[package].nil?
    @tags[package][tag] = value
    return value
  end

  # Set value of macro
  def set_macro_value(macro, value)
    if macro =~ /^S:(\d+)$/
      @macros["SOURCE#{$~[1]}"] = value
    elsif macro =~ /^P:(\d+)$/
      @macros["PATCH#{$~[1]}"] = value
    else
      @macros[macro] = value
    end
    return value
  end

  # Get value of macro
  # Source macros like %{S:1}, %{S:2} will be converted to %{SOURCE1}, %{SOURCE2}
  def get_macro_value(macro)
    if macro =~ /^S:(\d+)$/
      return @macros["SOURCE#{$~[1]}"]
    end
    if macro =~ /^P:(\d+)$/
      return @macros["PATCH#{$~[1]}"]
    end
    return @macros[macro]
  end

  # Expand macros to their values
  # Params:
  #   str - The string to be expanded
  # Return:
  #   ret - New string with macros expanded
  def expand_macros(str)
    ret = String.new(str)
    macros = ret.scan(/%\{[\w_\-:]\}/)
    macros.each do |key|
      value = self.get_macro_value(key)
      unless value.nil?
        ret.gsub!(/%\{#{key}\}/, value.to_s)
      end
    end
    return ret
  end

  # Split section line into section name and args
  # Params:
  #   line - The line to be parsed. Example: "%package doc"
  # Return:
  #   section_name  - Macro name. Example: "%package"
  #   args          - Arguments, such as subpackage name, program to run
  def get_section_and_args(line)
    return nil, nil unless line.start_with?('%')
    line =~ /^(%\w+)\s*(.*)$/
    return nil, nil if $~.nil?
    # get macro name and its value
    section_name = $~[1]
    args = ($~[2].length == 0) ? nil : $~[2]
    return section_name, args
  end

  # Parse the args of a section
  # Params:
  #   section_name  - Name of the section, including the % sign at the beginning
  #   arg_list      - Array of argument list(similar to ARGV)
  # Return:
  #   parsed_args   - Parsed arguments, e.g. {:args => [], :opts => {}}
  def parse_section_args!(section_name, arg_list)
    parsed_args = {:args => [], :opts => {}}
    opt_parser = OptionParser.new do |opts|
      opts.on('-n', 'Do not include primary package name in subpackage name') do
        if ['%description', '%files', '%changelog', '%package',
            '%pre', '%preun', '%post', '%postun'].include?(section_name)
          parsed_args[:opts]['-n'] = true
        end
      end

      opts.on('-f [FILE]', String, 'Read file list from a file') do |file|
        if section_name == '%files'
          file = self.expand_macros(file)
          parsed_args[:opts]['-f'] = [] if parsed_args[:opts]['-f'].nil?
          parsed_args[:opts]['-f'].push(file)
        end
      end

      opts.on('-p [PROGRAM]', String, 'Program to run') do |program|
        if ['%pre', '%preun', '%post', '%postun'].include?(section_name)
          program = self.expand_macros(program)
          parsed_args[:opts]['-p'] = program
        end
      end
    end
    opt_parser.parse!(arg_list)
    # Ignore other options
    parsed_args[:args] = arg_list.select do |item|
      item.start_with?('-') ? false : true
    end
    # Expand macros
    parsed_args[:args].map! do |item|
      self.expand_macros(item)
    end
    return parsed_args
  end

  def get_package_name(line_or_parsed_args)
    if line_or_parsed_args.instance_of?(String)
      section_name, args = self.get_section_and_args(line_or_parsed_args)
      line_or_parsed_args = self.parse_section_args!(section_name, args.split(' '))
    end
    arg = line_or_parsed_args[:args][-1]
    if line_or_parsed_args[:opts]['-n'] == true
      return arg.nil? ? 'main' : arg
    else
      name = self.get_macro_value('name')
      raise InvalidSpecError.new("get_package_name: Failed to get main package name")
      return arg.nil? ? 'main' : "#{name}-#{arg}"
    end
  end

  # Parse %packge section
  def parse_package_section_content(package_name, iter)
    loop do
      begin
        line = iter.next()
      rescue StopIteration
        break
      end
      line =~ /^(\w+)\s*:\s*([^\s].*)$/
      next if $~.nil?
      # Get tag name and value
      tag = $~[1]
      value = $~[2]
      # Set macro values if it's main package
      if package_name == 'main'
        if ['Name', 'Version', 'Release'].include?(tag)
          self.set_macro_value(tag.downcase, value) 
          self.set_macro_value('ver', value) if tag == 'Version'
        end
      end
      # Set tag name
      self.set_tag_value(package, tag, value)
    end
  end

  # Parse %packge section
  def parse_normal_section(package, section)
    iter = section.each_line
    # Section line
    line = iter.next()
    section, args = self.get_section_and_args(line)
    raise InvalidSpecError.new("parse_package_section: '#{section}' is not a %package section")
    parsed_args = self.parse_section_args!(section, args)
    package = self.get_package_name(line)
    loop do
      begin
        line = iter.next()
      rescue StopIteration
        break
      end
    end
  end

  def parse_section(section)
    iter = section.each_line
    # Section line
    line = iter.next
    section_name, args = self.get_section_and_args(line)
    parsed_args = self.parse_section_args!(section_name, args)
    package_name = self.get_package_name(line)
    if section_name == '%package'
      self.parse_package_section_content(package_name, iter)
    else
      self.parse_normal_section_content(package_name, iter)
    end
  end
end

parser = RpmSpecParser.new('../spec-parser/foo.spec')
puts parser.get_package_name({:args => ['foo', 'doc'], :opts => {'-n' => false}})
