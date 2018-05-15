# frozen_string_literal: true

require 'base64'
require 'hana'
require 'json'
require 'net/http'
require 'time'
require 'uri'

module JSONSchemer
  module Schema
    class Base
      include Format

      ID_KEYWORD = '$id'
      DEFAULT_REF_RESOLVER = proc { |uri| raise UnknownRef, uri.to_s }.freeze
      NET_HTTP_REF_RESOLVER = proc { |uri| JSON.parse(Net::HTTP.get(uri)) }.freeze
      BOOLEANS = Set[true, false].freeze

      def initialize(
        schema,
        format: true,
        formats: nil,
        keywords: nil,
        ref_resolver: DEFAULT_REF_RESOLVER
      )
        @root = schema
        @format = format
        @formats = formats
        @keywords = keywords
        @ref_resolver = ref_resolver == 'net/http' ? NET_HTTP_REF_RESOLVER : ref_resolver
      end

      def valid?(data, schema = root, pointer = '', parent_uri = nil)
        validate(data, schema, pointer, parent_uri).none?
      end

      def validate(data, schema = root, pointer = '', parent_uri = nil)
        return enum_for(:validate, data, schema, pointer, parent_uri) unless block_given?

        return if schema == true
        if schema == false
          yield error(data, schema, pointer, 'schema')
          return
        end

        return if schema.empty?

        type = schema['type']
        enum = schema['enum']
        all_of = schema['allOf']
        any_of = schema['anyOf']
        one_of = schema['oneOf']
        not_schema = schema['not']
        if_schema = schema['if']
        then_schema = schema['then']
        else_schema = schema['else']
        format = schema['format']
        ref = schema['$ref']
        id = schema[id_keyword]

        parent_uri = join_uri(parent_uri, id)

        if ref
          validate_ref(data, schema, pointer, parent_uri, ref, &Proc.new)
          return
        end

        validate_format(data, schema, pointer, format, &Proc.new) if format && format?

        if keywords
          keywords.each do |keyword, callable|
            if schema.key?(keyword)
              result = callable.call(data, schema, pointer)
              if result.is_a?(Array)
                result.each { |error| yield error }
              elsif !result
                yield error(data, schema, pointer, keyword)
              end
            end
          end
        end

        yield error(data, schema, pointer, 'enum') if enum && !enum.include?(data)
        yield error(data, schema, pointer, 'const') if schema.key?('const') && schema['const'] != data

        if all_of
          subschemas = all_of.lazy.map { |subschema| validate(data, subschema, pointer, parent_uri) }
          yield error(data, schema, pointer, 'allOf', subschemas) unless subschemas.all?(&:none?)
        end

        if any_of
          subschemas = any_of.lazy.map { |subschema| validate(data, subschema, pointer, parent_uri) }
          yield error(data, schema, pointer, 'anyOf', subschemas) unless subschemas.any?(&:none?)
        end

        if one_of
          subschemas = one_of.lazy.map { |subschema| validate(data, subschema, pointer, parent_uri) }
          yield error(data, schema, pointer, 'oneOf', subschemas) unless subschemas.one?(&:none?)
        end

        yield error(data, schema, pointer, 'not') if !not_schema.nil? && valid?(data, not_schema, pointer, parent_uri)

        if if_schema && valid?(data, if_schema, pointer, parent_uri)
          validate(data, then_schema, pointer, parent_uri, &Proc.new) unless then_schema.nil?
        elsif if_schema
          validate(data, else_schema, pointer, parent_uri, &Proc.new) unless else_schema.nil?
        end

        case type
        when nil
          validate_class(data, schema, pointer, parent_uri, &Proc.new)
        when String
          validate_type(data, schema, pointer, parent_uri, type, &Proc.new)
        when Array
          if valid_type = type.find { |subtype| valid?(data, { 'type' => subtype }, pointer, parent_uri) }
            validate_type(data, schema, pointer, parent_uri, valid_type, &Proc.new)
          else
            yield error(data, schema, pointer, 'type')
          end
        end
      end

    protected

      def ids
        @ids ||= resolve_ids(root)
      end

    private

      attr_reader :root, :formats, :keywords, :ref_resolver

      def id_keyword
        ID_KEYWORD
      end

      def format?
        !!@format
      end

      def child(schema)
        JSONSchemer.schema(
          schema,
          format: format?,
          formats: formats,
          keywords: keywords,
          ref_resolver: ref_resolver
        )
      end

      def error(data, schema, pointer, type, subschemas = nil)
        {
          'data' => data,
          'schema' => schema,
          'pointer' => pointer,
          'type' => type,
          'subschemas' => subschemas
        }
      end

      def validate_class(data, schema, pointer, parent_uri)
        case data
        when Integer
          validate_integer(data, schema, pointer, &Proc.new)
        when Numeric
          validate_number(data, schema, pointer, &Proc.new)
        when String
          validate_string(data, schema, pointer, &Proc.new)
        when Array
          validate_array(data, schema, pointer, parent_uri, &Proc.new)
        when Hash
          validate_object(data, schema, pointer, parent_uri, &Proc.new)
        end
      end

      def validate_type(data, schema, pointer, parent_uri, type)
        case type
        when 'null'
          yield error(data, schema, pointer, 'null') unless data.nil?
        when 'boolean'
          yield error(data, schema, pointer, 'boolean') unless BOOLEANS.include?(data)
        when 'number'
          validate_number(data, schema, pointer, &Proc.new)
        when 'integer'
          validate_integer(data, schema, pointer, &Proc.new)
        when 'string'
          validate_string(data, schema, pointer, &Proc.new)
        when 'array'
          validate_array(data, schema, pointer, parent_uri, &Proc.new)
        when 'object'
          validate_object(data, schema, pointer, parent_uri, &Proc.new)
        end
      end

      def validate_ref(data, schema, pointer, parent_uri, ref)
        ref_uri = join_uri(parent_uri, ref)

        if valid_json_pointer?(ref_uri.fragment)
          ref_pointer = Hana::Pointer.new(URI.unescape(ref_uri.fragment || ''))
          if ref.start_with?('#')
            validate(data, ref_pointer.eval(root), pointer, pointer_uri(root, ref_pointer), &Proc.new)
          else
            ref_root = ref_resolver.call(ref_uri)
            ref_object = child(ref_root)
            ref_object.validate(data, ref_pointer.eval(ref_root), pointer, pointer_uri(ref_root, ref_pointer), &Proc.new)
          end
        elsif ids.key?(ref_uri.to_s)
          validate(data, ids.fetch(ref_uri.to_s), pointer, ref_uri, &Proc.new)
        else
          ref_root = ref_resolver.call(ref_uri)
          ref_object = child(ref_root)
          ref_object.validate(data, ref_object.ids.fetch(ref_uri.to_s, ref_root), pointer, ref_uri, &Proc.new)
        end
      end

      def validate_format(data, schema, pointer, format)
        valid = if formats && formats.key?(format)
          format_option = formats[format]
          format_option == false || format_option.call(data, schema)
        elsif supported_format?(format)
          valid_format?(data, format)
        end
        yield error(data, schema, pointer, 'format') unless valid
      end

      def validate_exclusive_maximum(data, schema, pointer, exclusive_maximum, maximum)
        yield error(data, schema, pointer, 'exclusiveMaximum') if data >= exclusive_maximum
      end

      def validate_exclusive_minimum(data, schema, pointer, exclusive_minimum, minimum)
        yield error(data, schema, pointer, 'exclusiveMinimum') if data <= exclusive_minimum
      end

      def validate_numeric(data, schema, pointer)
        multiple_of = schema['multipleOf']
        maximum = schema['maximum']
        exclusive_maximum = schema['exclusiveMaximum']
        minimum = schema['minimum']
        exclusive_minimum = schema['exclusiveMinimum']

        yield error(data, schema, pointer, 'maximum') if maximum && data > maximum
        yield error(data, schema, pointer, 'minimum') if minimum && data < minimum

        validate_exclusive_maximum(data, schema, pointer, exclusive_maximum, maximum, &Proc.new) if exclusive_maximum
        validate_exclusive_minimum(data, schema, pointer, exclusive_minimum, minimum, &Proc.new) if exclusive_minimum

        if multiple_of
          quotient = data / multiple_of.to_f
          yield error(data, schema, pointer, 'multipleOf') unless quotient.floor == quotient
        end
      end

      def validate_number(data, schema, pointer)
        unless data.is_a?(Numeric)
          yield error(data, schema, pointer, 'number')
          return
        end

        validate_numeric(data, schema, pointer, &Proc.new)
      end

      def validate_integer(data, schema, pointer)
        if !data.is_a?(Numeric) || (!data.is_a?(Integer) && data.floor != data)
          yield error(data, schema, pointer, 'integer')
          return
        end

        validate_numeric(data, schema, pointer, &Proc.new)
      end

      def validate_string(data, schema, pointer)
        unless data.is_a?(String)
          yield error(data, schema, pointer, 'string')
          return
        end

        max_length = schema['maxLength']
        min_length = schema['minLength']
        pattern = schema['pattern']
        content_encoding = schema['contentEncoding']
        content_media_type = schema['contentMediaType']

        yield error(data, schema, pointer, 'maxLength') if max_length && data.size > max_length
        yield error(data, schema, pointer, 'minLength') if min_length && data.size < min_length
        yield error(data, schema, pointer, 'pattern') if pattern && Regexp.new(pattern) !~ data

        if content_encoding || content_media_type
          decoded_data = data

          if content_encoding
            decoded_data = case content_encoding.downcase
            when 'base64'
              safe_strict_decode64(data)
            else # '7bit', '8bit', 'binary', 'quoted-printable'
              raise NotImplementedError
            end
            yield error(data, schema, pointer, 'contentEncoding') unless decoded_data
          end

          if content_media_type && decoded_data
            case content_media_type.downcase
            when 'application/json'
              yield error(data, schema, pointer, 'contentMediaType') unless valid_json?(decoded_data)
            else
              raise NotImplementedError
            end
          end
        end
      end

      def validate_array(data, schema, pointer, parent_uri, &block)
        unless data.is_a?(Array)
          yield error(data, schema, pointer, 'array')
          return
        end

        items = schema['items']
        additional_items = schema['additionalItems']
        max_items = schema['maxItems']
        min_items = schema['minItems']
        unique_items = schema['uniqueItems']
        contains = schema['contains']

        yield error(data, schema, pointer, 'maxItems') if max_items && data.size > max_items
        yield error(data, schema, pointer, 'minItems') if min_items && data.size < min_items
        yield error(data, schema, pointer, 'uniqueItems') if unique_items && data.size != data.uniq.size

        unless contains.nil?
          subschemas = data.lazy.map { |subschema| validate(subschema, contains, pointer, parent_uri) }
          yield error(data, schema, pointer, 'contains', subschemas) if subschemas.all?(&:any?)
        end

        if items.is_a?(Array)
          data.each_with_index do |item, index|
            if index < items.size
              validate(item, items[index], "#{pointer}/#{index}", parent_uri, &block)
            elsif !additional_items.nil?
              validate(item, additional_items, "#{pointer}/#{index}", parent_uri, &block)
            else
              break
            end
          end
        elsif !items.nil?
          data.each_with_index do |item, index|
            validate(item, items, "#{pointer}/#{index}", parent_uri, &block)
          end
        end
      end

      def validate_object(data, schema, pointer, parent_uri, &block)
        unless data.is_a?(Hash)
          yield error(data, schema, pointer, 'object')
          return
        end

        max_properties = schema['maxProperties']
        min_properties = schema['minProperties']
        required = schema['required']
        properties = schema['properties']
        pattern_properties = schema['patternProperties']
        additional_properties = schema['additionalProperties']
        dependencies = schema['dependencies']
        property_names = schema['propertyNames']

        if dependencies
          dependencies.each do |key, value|
            next unless data.key?(key)
            subschema = value.is_a?(Array) ? { 'required' => value } : value
            validate(data, subschema, pointer, parent_uri, &block)
          end
        end

        yield error(data, schema, pointer, 'maxProperties') if max_properties && data.size > max_properties
        yield error(data, schema, pointer, 'minProperties') if min_properties && data.size < min_properties
        yield error(data, schema, pointer, 'required') if required && required.any? { |key| !data.key?(key) }

        regex_pattern_properties = nil
        data.each do |key, value|
          validate(key, property_names, pointer, parent_uri, &block) unless property_names.nil?

          matched_key = false

          if properties && properties.key?(key)
            validate(value, properties[key], "#{pointer}/#{key}", parent_uri, &block)
            matched_key = true
          end

          if pattern_properties
            regex_pattern_properties ||= pattern_properties.map do |pattern, property_schema|
              [Regexp.new(pattern), property_schema]
            end
            regex_pattern_properties.each do |regex, property_schema|
              if regex =~ key
                validate(value, property_schema, "#{pointer}/#{key}", parent_uri, &block)
                matched_key = true
              end
            end
          end

          next if matched_key

          validate(value, additional_properties, "#{pointer}/#{key}", parent_uri, &block) unless additional_properties.nil?
        end
      end

      def safe_strict_decode64(data)
        begin
          Base64.strict_decode64(data)
        rescue ArgumentError => e
          raise e unless e.message == 'invalid base64'
          nil
        end
      end

      def join_uri(a, b)
        if a && b
          URI.join(a, b)
        elsif b
          URI.parse(b)
        else
          a
        end
      end

      def pointer_uri(schema, pointer)
        uri_parts = nil
        pointer.reduce(schema) do |obj, token|
          next obj.fetch(token.to_i) if obj.is_a?(Array)
          if obj_id = obj[id_keyword]
            uri_parts ||= []
            uri_parts << obj_id
          end
          obj.fetch(token)
        end
        uri_parts ? URI.join(*uri_parts) : nil
      end

      def resolve_ids(schema, ids = {}, parent_uri = nil)
        if schema.is_a?(Array)
          schema.each { |subschema| resolve_ids(subschema, ids, parent_uri) }
        elsif schema.is_a?(Hash)
          id = schema[id_keyword]
          uri = join_uri(parent_uri, id)
          ids[uri.to_s] = schema unless uri == parent_uri
          if definitions = schema['definitions']
            definitions.each_value { |subschema| resolve_ids(subschema, ids, uri) }
          end
        end
        ids
      end
    end
  end
end
