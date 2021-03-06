defmodule Spect do
  @moduledoc """
  elixir typespec enhancements
  """

  use Memoize

  defmodule ConvertError do
    defexception message: "could not map to spec"
  end

  @doc """
  typespec-driven object decoding

  This function converts a data structure into a new one derived from a type
  specification. This provides for the effective decoding of (nested) data
  structures from serialization formats that do not support Elixir's rich
  set of types (json, etc.). Atoms can be decoded from strings, tuples from
  lists, structs from maps, etc.

  `data` is the data structure to decode, `module` is the name of the module
  containing the type specification, and `name` is the name of the @type
  definition within the module (defaults to `:t`).

  As mentioned above, a common use case is to decode a JSON document into
  an Elixir struct, for example using the poison parser:
    ```elixir
      "test.json"
      |> File.read!()
      |> Poison.Parser.parse!()
      |> Spect.to_spec!(My.Master)
    ```

  where the `My` module might contain the following structs:
    ```elixir
      defmodule My do
        defmodule Master do
          @type t :: %__MODULE__{
            rest: integer(),
            details: %{String.t() => My.Detail.t()}
          }
          defstruct [rest: 2, details: %{}]
        end

        defmodule Detail do
          @type t :: %__MODULE__{
            nest: integer()
          }
          defstruct [nest: 1]
        end
      end
    ```
  """
  @spec to_spec(data :: any, module :: atom, name :: atom) ::
          {:ok, any} | {:error, any}
  def to_spec(data, module, name \\ :t) do
    {:ok, to_spec!(data, module, name)}
  rescue
    e -> {:error, e}
  end

  @doc """
  decodes an object from a typespec, raising on error
  """
  @spec to_spec!(data :: any, module :: atom, name :: atom) :: any
  def to_spec!(data, module, name \\ :t) do
    types = load_types(module)

    if types === nil do
      raise ArgumentError, "module not found: #{module}"
    end

    types
    |> Keyword.values()
    |> Enum.filter(fn {k, _v, _a} -> k == name end)
    |> case do
      [{^name, type, _args}] -> to_kind!(data, module, type)
      _ -> raise ArgumentError, "type not found: #{module}.#{name}"
    end
  end

  defmemo load_types(module) do
    Kernel.Typespec.beam_types(module)
  end

  # -------------------------------------------------------------------------
  # top-level kind demultiplexing
  # -------------------------------------------------------------------------

  defp to_kind!(data, module, {:type, _line, type, args}) do
    to_type!(data, module, type, args)
  end

  defp to_kind!(data, _module, {:remote_type, _line, type}) do
    [{:atom, _, module}, {:atom, _, name}, []] = type

    if module == DateTime and name == :t do
      to_datetime!(data)
    else
      to_spec!(data, module, name)
    end
  end

  defp to_kind!(data, module, {:ann_type, _line, [{:var, _, _name}, type]}) do
    to_kind!(data, module, type)
  end

  defp to_kind!(data, module, {:user_type, _line, name, _args}) do
    to_spec!(data, module, name)
  end

  defp to_kind!(data, _module, {kind, _line, value}) do
    to_lit!(data, kind, value)
  end

  # -------------------------------------------------------------------------
  # literals
  # -------------------------------------------------------------------------

  # string->atom
  defp to_lit!(data, :atom, value) when is_binary(data) do
    ^value = String.to_existing_atom(data)
  rescue
    _ -> reraise(ConvertError, "invalid atom: #{value}", System.stacktrace())
  end

  # atom/bool/integer literal
  defp to_lit!(data, _kind, value) do
    if data === value do
      value
    else
      raise(ConvertError, "expected: #{value}, found: #{inspect(data)}")
    end
  end

  # -------------------------------------------------------------------------
  # types
  # -------------------------------------------------------------------------

  # any type
  defp to_type!(data, _module, :any, _args) do
    data
  end

  # none type
  defp to_type!(_data, _module, :none, _args) do
    raise ConvertError
  end

  # atom
  defp to_type!(data, _module, :atom, _args) do
    cond do
      is_atom(data) -> data
      is_binary(data) -> String.to_existing_atom(data)
      true -> raise ArgumentError
    end
  rescue
    _ ->
      reraise(
        ConvertError,
        "invalid atom: #{inspect(data)}",
        System.stacktrace()
      )
  end

  defp to_type!(data, module, :module, _args) do
    to_type!(data, module, :atom, [])
  end

  # boolean
  defp to_type!(data, _module, :boolean, _args) do
    if is_boolean(data) do
      data
    else
      raise(ConvertError, "expected: boolean, found: #{inspect(data)}")
    end
  end

  # integer
  defp to_type!(data, _module, :integer, _args) do
    if is_integer(data) do
      data
    else
      raise(ConvertError, "expected: integer, found: #{inspect(data)}")
    end
  end

  # float
  defp to_type!(data, _module, :float, _args) do
    if is_float(data) do
      data
    else
      raise(ConvertError, "expected: float, found: #{inspect(data)}")
    end
  end

  # number
  defp to_type!(data, _module, :number, _args) do
    if is_number(data) do
      data
    else
      raise(ConvertError, "expected: number, found: #{inspect(data)}")
    end
  end

  # negative integer
  defp to_type!(data, _module, :neg_integer, _args) do
    if is_integer(data) and data < 0 do
      data
    else
      raise(
        ConvertError,
        "expected: negative integer, found: #{inspect(data)}"
      )
    end
  end

  # non-negative integer
  defp to_type!(data, _module, :non_neg_integer, _args) do
    if is_integer(data) and data >= 0 do
      data
    else
      raise(
        ConvertError,
        "expected: non-negative integer, found: #{inspect(data)}"
      )
    end
  end

  # positive integer
  defp to_type!(data, _module, :pos_integer, _args) do
    if is_integer(data) and data > 0 do
      data
    else
      raise(
        ConvertError,
        "expected: positive integer, found: #{inspect(data)}"
      )
    end
  end

  # string
  defp to_type!(data, _module, :binary, _args) do
    if is_binary(data) do
      data
    else
      raise(ConvertError, "expected: string, found: #{inspect(data)}")
    end
  end

  # union a | b | c, return the first match, recursive
  defp to_type!(data, module, :union, types) do
    result =
      Enum.reduce_while(types, ConvertError, fn type, result ->
        try do
          {:halt, to_kind!(data, module, type)}
        rescue
          _ -> {:cont, result}
        end
      end)

    with ConvertError <- result do
      raise ConvertError,
            "expected: union of #{inspect(types)}, found: #{inspect(data)}"
    end
  end

  # tuple
  defp to_type!(data, module, :tuple, args) do
    to_tuple!(data, module, args)
  end

  # list
  defp to_type!(data, module, :list, args) do
    to_list!(data, module, args)
  end

  # empty list
  defp to_type!(data, _module, nil, []) do
    if is_list(data) do
      data
    else
      raise(ConvertError, "expected: list, found: #{inspect(data)}")
    end
  end

  # map
  defp to_type!(data, module, :map, args) do
    to_map!(data, module, args)
  end

  # -------------------------------------------------------------------------
  # tuple types
  # -------------------------------------------------------------------------

  # any tuple, list->tuple
  defp to_tuple!(data, _module, :any) do
    cond do
      is_tuple(data) -> data
      is_list(data) -> List.to_tuple(data)
      true -> raise(ConvertError, "expected: tuple, found: #{inspect(data)}")
    end
  end

  # exact tuple, list->tuple, recursive
  defp to_tuple!(data, module, types) do
    cond do
      is_tuple(data) ->
        to_tuple!(Tuple.to_list(data), module, types)

      is_list(data) and length(data) === length(types) ->
        Enum.reduce(Enum.zip(data, types), {}, fn {data, type}, result ->
          Tuple.append(result, to_kind!(data, module, type))
        end)

      true ->
        raise(ConvertError, "expected: tuple, found: #{inspect(data)}")
    end
  end

  # -------------------------------------------------------------------------
  # list types
  # -------------------------------------------------------------------------

  # typed list, recursive
  defp to_list!(data, module, [type]) do
    if is_list(data) do
      Enum.map(data, &to_kind!(&1, module, type))
    else
      raise(ConvertError, "expected: list, found: #{inspect(data)}")
    end
  end

  # any list
  defp to_list!(data, _module, []) do
    if is_list(data) do
      data
    else
      raise(ConvertError, "expected: list, found: #{inspect(data)}")
    end
  end

  # -------------------------------------------------------------------------
  # map types
  # -------------------------------------------------------------------------

  # any map -> struct-like map
  defp to_map!(data, _module, [
         {:type, _, :map_field_exact,
          [{:atom, _, :__struct__}, {:type, _, :atom, []}]}
         | _fields
       ]) do
    if is_map(data) do
      Map.new(Map.to_list(data), fn
        {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
        {k, v} -> {k, v}
      end)
    else
      raise(ConvertError, "expected: map, found: #{inspect(data)}")
    end
  end

  # any map -> exact struct, recursive
  defp to_map!(data, module, [
         {:type, _, :map_field_exact,
          [{:atom, _, :__struct__}, {:atom, _, struct}]}
         | fields
       ]) do
    if is_map(data) do
      Enum.reduce(fields, Kernel.struct(struct), fn field, result ->
        {:type, _line, :map_field_exact, [{:atom, _, k}, type]} = field

        if Map.has_key?(data, k) do
          Map.put(result, k, to_kind!(Map.get(data, k), module, type))
        else
          sk = to_string(k)

          if Map.has_key?(data, sk) do
            Map.put(result, k, to_kind!(Map.get(data, sk), module, type))
          else
            result
          end
        end
      end)
    else
      raise(ConvertError, "expected: map, found: #{inspect(data)}")
    end
  end

  # empty map
  defp to_map!(data, _module, []) do
    if is_map(data) do
      data
    else
      raise(ConvertError, "expected: map, found: #{inspect(data)}")
    end
  end

  # any map
  defp to_map!(data, _module, :any) do
    if is_map(data) do
      data
    else
      raise(ConvertError, "expected: map, found: #{inspect(data)}")
    end
  end

  # any typed map, recursive
  defp to_map!(data, module, [{:type, _line, _mode, [key_field, val_field]}])
       when elem(key_field, 0) in [
              :type,
              :remote_type,
              :ann_type,
              :user_type
            ] do
    if is_map(data) do
      Enum.reduce(Map.to_list(data), %{}, fn {k, v}, r ->
        Map.put(
          r,
          to_kind!(k, module, key_field),
          to_kind!(v, module, val_field)
        )
      end)
    else
      raise(ConvertError, "expected: map, found: #{inspect(data)}")
    end
  end

  # any map, exact keys, recursive
  defp to_map!(data, module, fields) do
    if is_map(data) do
      Enum.reduce(fields, %{}, fn field, result ->
        {:type, _line, _mode, [{_, _, k}, type]} = field

        if Map.has_key?(data, k) do
          Map.put(result, k, to_kind!(Map.get(data, k), module, type))
        else
          sk = to_string(k)

          if Map.has_key?(data, sk) do
            Map.put(result, k, to_kind!(Map.get(data, sk), module, type))
          else
            result
          end
        end
      end)
    else
      raise(ConvertError, "expected: map, found: #{inspect(data)}")
    end
  end

  # -------------------------------------------------------------------------
  # miscellaneous types
  # -------------------------------------------------------------------------

  defp to_datetime!(data) do
    cond do
      is_binary(data) ->
        case DateTime.from_iso8601(data) do
          {:ok, dt, _utc_offset} ->
            dt

          {:error, reason} ->
            raise(
              ConvertError,
              "invalid string format for DateTime: #{reason}"
            )
        end

      is_map(data) and data.__struct__ == DateTime ->
        data

      true ->
        raise(
          ConvertError,
          "expected ISO8601 string or DateTime struct, found: #{inspect(data)}"
        )
    end
  end
end
