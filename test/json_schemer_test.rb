require 'test_helper'
require 'json'

class JSONSchemerTest < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::JSONSchemer::VERSION
  end

  def test_it_does_something_useful
    schema = {
      'type' => 'object',
      'maxProperties' => 4,
      'minProperties' => 1,
      'required' => [
        'one'
      ],
      'properties' => {
        'one' => {
          'type' => 'string',
          'maxLength' => 5,
          'minLength' => 3,
          'pattern' => '\w+'
        },
        'two' => {
          'type' => 'integer',
          'minimum' => 10,
          'maximum' => 100,
          'multipleOf' => 5
        },
        'three' => {
          'type' => 'array',
          'maxItems' => 2,
          'minItems' => 2,
          'uniqueItems' => true,
          'contains' => {
            'type' => 'integer'
          }
        }
      },
      'additionalProperties' => {
        'type' => 'string'
      },
      'propertyNames' => {
        'type' => 'string',
        'pattern' => '\w+'
      },
      'dependencies' => {
        'one' => [
          'two'
        ],
        'two' => {
          'minProperties' => 1
        }
      }
    }
    data = {
      'one' => 'value',
      'two' => 100,
      'three' => [1, 2],
      '123' => 'x'
    }
    schema = JSONSchemer.schema(schema)
    assert schema.valid?(data)
    errors = schema.validate(data)
    assert errors.none?
  end

  def test_error_subschemas
    schema = {
      'allOf' => [
        {
          'type' => 'integer',
          'maximum' => 1
        },
        {
          'type' => 'integer',
          'maximum' => 10
        }
      ]
    }
    schema = JSONSchemer.schema(schema)
    error = schema.validate(11).first
    assert error.fetch('type') == 'allOf'
    assert error.fetch('subschemas').flat_map(&:to_a).map { |e| e.fetch('type') }.to_a == ['maximum', 'maximum']
  end

  {
    'draft4' => JSONSchemer::Schema::Draft4,
    'draft6' => JSONSchemer::Schema::Draft6,
    'draft7' => JSONSchemer::Schema::Draft7
  }.each do |version, draft_class|
    Dir["JSON-Schema-Test-Suite/tests/#{version}/**/*.json"].each_with_index do |file, file_index|
      JSON.parse(File.read(file)).each_with_index do |defn, defn_index|
        defn.fetch('tests').each_with_index do |test, test_index|
          define_method("test_json_schema_test_suite_#{version}_#{file_index}_#{defn_index}_#{test_index}") do
            errors = begin
              draft_class.new(
                defn.fetch('schema'),
                :ref_resolver => 'net/http'
              ).validate(test.fetch('data')).to_a
            rescue StandardError, NotImplementedError => e
              [e.class, e.message]
            end
            if test.fetch('valid')
              assert_empty(errors, file)
            else
              assert(errors.any?, file)
            end
          end
        end
      end
    end
  end
end
