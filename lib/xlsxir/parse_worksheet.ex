defmodule Xlsxir.ParseWorksheet do
  alias Xlsxir.{ConvertDate, ConvertDateTime, SaxError}
  import Xlsxir.ConvertDate, only: [convert_char_number: 1]
  require Logger

  @moduledoc """
  Holds the SAX event instructions for parsing worksheet data via `Xlsxir.SaxParser.parse/2`
  """

  defstruct row: [],
            cells: %{},
            cell_ref: "",
            data_type: "",
            num_style: "",
            value: "",
            formula: nil,
            formula_si: nil,
            formula_ref: nil,
            formula_origin: nil,
            value_type: nil,
            max_rows: nil,
            tid: nil

  @doc """
  Sax event utilized by `Xlsxir.SaxParser.parse/2`. Takes a pattern and the current state of a struct and recursivly parses the
  worksheet XML file, ultimately saving a list of cell references and their assocated values to the ETS process.

  ## Parameters

  - `arg1` - the XML pattern of the event to match upon
  - `state` - the state of the `%Xlsxir.ParseWorksheet{}` struct which temporarily holds applicable data of the current row being parsed

  ## Example
  Each entry in the list created consists of a list containing a cell reference string and the associated value (i.e. `[["A1", "string one"], ...]`).
  """
  def sax_event_handler(
        :startDocument,
        _state,
        %{max_rows: max_rows, workbook: workbook_tid},
        xml_name
      ) do
    tid = GenServer.call(Xlsxir.StateManager, :new_table)

    "sheet" <> remained = xml_name
    {sheet_id, _} = Integer.parse(remained)

    worksheet_name =
      List.foldl(:ets.lookup(workbook_tid, sheet_id), nil, fn value, _ ->
        case value do
          {_, worksheet_name} -> worksheet_name
          _ -> nil
        end
      end)

    # [{_, worksheet_name} | _] = :ets.lookup(workbook_tid, rid)

    :ets.insert(tid, {:info, :worksheet_name, worksheet_name})

    %__MODULE__{tid: tid, max_rows: max_rows}
  end

  def sax_event_handler(
        {:startElement, _, 'row', _, _},
        %__MODULE__{tid: tid, max_rows: max_rows, cells: cells},
        _excel,
        _
      ) do
    %__MODULE__{tid: tid, max_rows: max_rows, cells: cells}
  end

  def sax_event_handler({:startElement, _, 'c', _, xml_attr}, state, %{styles: styles_tid}, _) do
    a =
      Enum.reduce(xml_attr, %{}, fn attr, acc ->
        case attr do
          {:attribute, 's', _, _, style} ->
            Map.put(acc, "s", find_styles(styles_tid, List.to_integer(style)))

          {:attribute, key, _, _, ref} ->
            Map.put(acc, to_string(key), ref)
        end
      end)

    {cell_ref, num_style, data_type} = {a["r"], a["s"], a["t"]}

    %{state | cell_ref: cell_ref, num_style: num_style, data_type: data_type}
  end

  # <c r=\"B2\" s=\"9\" t=\"str\"><f t=\"array\" ref=\"B2\">XLOOKUP(2,G2:G1001,M2:M1001)</f><v>B</v></c>
  defp cell_formula(
         %{shared_strings: _strings_tid} = _excel,
         state,
         %{
           "t" => 'array',
           "ref" => ref
         }
       ) do
    %{
      state
      | value_type: :formula,
        formula_ref: ref
    }
  end

  # <c r="D2" s="10" t="b"><f t="shared" ref="D2:D5" si="1">B2=C2</f><v>1</v></c>
  defp cell_formula(
         %{shared_strings: _strings_tid} = _excel,
         state,
         %{
           "si" => si,
           "t" => 'shared',
           "ref" => ref
         }
       ) do
    %{
      state
      | value_type: :formula,
        formula_ref: ref,
        formula_si: si
    }
  end

  # <c r="D4" s="10" t="str"><f t="shared" si="1"/><v>#VALUE!</v>
  defp cell_formula(
         %{shared_strings: _strings_tid} = _excel,
         state,
         %{
           "si" => si,
           "t" => 'shared'
         } = attributes
       )
       when is_map_key(attributes, "ref") == false do
    {formula_ref, [_, %{formula: formula}]} =
      Enum.find(state.cells, fn {_, [_ref, cell]} ->
        cell.formula_si == si and cell.formula_ref != nil
      end)

    %{
      state
      | value_type: :shared_formula,
        formula_si: si,
        formula: formula,
        formula_origin: formula_ref
    }
  end

  # When f has three attributes
  def sax_event_handler({:startElement, _, 'f', _, [_, _, _] = xml_attr}, state, excel, sheet) do
    attributes =
      Enum.reduce(xml_attr, %{}, fn {:attribute, key, _, _, ref}, acc ->
        Map.put(acc, to_string(key), ref)
      end)

    cell_formula(excel, state, attributes)
  end

  # When f has two attributes
  def sax_event_handler({:startElement, _, 'f', _, [_, _] = xml_attr}, state, excel, sheet) do
    attributes =
      Enum.reduce(xml_attr, %{}, fn {:attribute, key, _, _, ref}, acc ->
        Map.put(acc, to_string(key), ref)
      end)

    cell_formula(excel, state, attributes)
  end

  # When f has a value
  def sax_event_handler({:startElement, _, 'f', _, []}, state, _, _) do
    %{state | value_type: :formula}
  end

  def sax_event_handler({:startElement, _, el, _, _}, state, _, _) when el in ['v', 't'] do
    %{state | value_type: :value}
  end

  def sax_event_handler({:endElement, _, el, _, _}, state, _, _) when el in ['v', 't', 'f'] do
    %{state | value_type: nil}
  end

  def sax_event_handler({:startElement, _, 'is', _, _}, state, _, _),
    do: %{state | value_type: :value}

  # def sax_event_handler({:characters, value}, state, _, _) do
  #   case state do
  #     nil -> nil
  #     %{value_type: :value} -> %{state | value: value}
  #     %{value_type: :formula} -> %{state | formula: value}
  #     _ -> state
  #   end
  # end

  def sax_event_handler({:characters, value}, nil, _, _) do
    nil
  end

  def sax_event_handler({:characters, value}, %{value_type: :value} = state, _, _) do
    %{state | value: value}
  end

  def sax_event_handler({:characters, value}, %{value_type: :formula} = state, _, _) do
    %{state | formula: value}
  end

  def sax_event_handler({:endElement, _, 'c', _}, %__MODULE__{row: row} = state, excel, sheet) do
    cell_value = format_cell_value(excel, [state.data_type, state.num_style, state.value])

    new_cell = [
      to_string(state.cell_ref),
      %{
        cell_value: cell_value,
        data_type: state.data_type,
        num_style: state.num_style,
        value: state.value,
        value_type: state.value_type,
        formula: state.formula,
        formula_si: state.formula_si,
        formula_ref: state.formula_ref,
        formula_origin: state.formula_origin
      }
    ]

    %{
      state
      | row: [new_cell | row],
        cells: Map.put(state.cells, state.cell_ref, new_cell),
        cell_ref: "",
        data_type: "",
        num_style: "",
        value: "",
        formula: nil,
        formula_si: nil,
        formula_ref: nil,
        formula_origin: nil
    }
  end

  def sax_event_handler(
        {:endElement, _, 'row', _},
        %__MODULE__{tid: tid, max_rows: max_rows, cells: cells} = state,
        _excel,
        _
      ) do
    unless Enum.empty?(state.row) do
      [[row]] = ~r/\d+/ |> Regex.scan(state.row |> List.first() |> List.first())
      row = row |> String.to_integer()
      value = state.row |> Enum.reverse() |> fill_nil()

      :ets.insert(tid, {row, value})
      if !is_nil(max_rows) and row == max_rows, do: raise(SaxError, state: state)
    end

    state
  end

  def sax_event_handler(_, state, _, _), do: state

  defp fill_nil(rows) do
    Enum.reduce(rows, {[], nil}, fn [ref, val], {values, previous} ->
      line = ~r/\d+$/ |> Regex.run(ref) |> List.first()

      empty_cells =
        cond do
          is_nil(previous) && String.first(ref) != "A" ->
            fill_empty_cells("A#{line}", ref, line, [])

          !is_nil(previous) && !is_next_col(ref, previous) ->
            fill_empty_cells(next_col(previous), ref, line, [])

          true ->
            []
        end

      {values ++ empty_cells ++ [[ref, val]], ref}
    end)
    |> elem(0)
  end

  def column_from_index(index, column) when index > 0 do
    modulo = rem(index - 1, 26)
    column = [65 + modulo | column]
    column_from_index(div(index - modulo, 26), column)
  end

  def column_from_index(_, column), do: to_string(column)

  defp is_next_col(current, previous) do
    current == next_col(previous)
  end

  def next_col(ref) do
    [chars, line] = Regex.run(~r/^([A-Z]+)(\d+)/, ref, capture: :all_but_first)
    chars = chars |> String.to_charlist()

    col_index =
      Enum.reduce(chars, 0, fn char, acc ->
        acc = acc * 26
        acc + char - 65 + 1
      end)

    "#{column_from_index(col_index + 1, '')}#{line}"
  end

  def fill_empty_cells(from, from, _line, cells), do: Enum.reverse(cells)

  def fill_empty_cells(from, to, line, cells) do
    next_ref = next_col(from)

    if next_ref == to do
      fill_empty_cells(to, to, line, [[from, nil] | cells])
    else
      fill_empty_cells(next_ref, to, line, [[from, nil] | cells])
    end
  end

  defp format_cell_value(%{shared_strings: strings_tid}, list) do
    case list do
      # Cell with no value attribute
      [_, _, nil] -> nil
      # Empty cell with assigned attribute
      [_, _, ""] -> nil
      # Type error
      ['e', _, e] -> List.to_string(e)
      # Type string
      ['s', _, i] -> find_string(strings_tid, List.to_integer(i))
      # Type number
      [nil, nil, n] -> convert_char_number(n)
      ['n', nil, n] -> convert_char_number(n)
      # ISO 8601 type date
      [nil, 'd', d] -> convert_date_or_time(d)
      ['n', 'd', d] -> convert_date_or_time(d)
      ['d', 'd', d] -> convert_iso_date(d)
      # Type formula w/ string
      ['str', _, s] -> List.to_string(s)
      # Type boolean
      ['b', _, s] -> s == '1'
      # Type string
      ['inlineStr', _, s] -> List.to_string(s)
      # Unmapped type
      _ -> raise "Unmapped attribute #{Enum.at(list, 0)}. Unable to process"
    end
  end

  defp convert_iso_date(value) do
    str = value |> List.to_string()

    with {:ok, date} <- str |> Date.from_iso8601() do
      date |> Date.to_erl()
    else
      {:error, _} ->
        with {:ok, datetime} <- str |> NaiveDateTime.from_iso8601() do
          datetime
        else
          {:error, _} -> str
        end
    end
  end

  defp convert_date_or_time(value) do
    str = List.to_string(value)

    if str == "0" || String.match?(str, ~r/\d\.\d+/) do
      ConvertDateTime.from_charlist(value)
    else
      ConvertDate.from_serial(value)
    end
  end

  defp find_styles(nil, _index), do: nil

  defp find_styles(tid, index) do
    tid
    |> :ets.lookup(index)
    |> List.first()
    |> case do
      nil ->
        nil

      {_, i} ->
        i
    end
  end

  defp find_string(nil, _index), do: nil

  defp find_string(tid, index) do
    tid
    |> :ets.lookup(index)
    |> List.first()
    |> elem(1)
  end
end
