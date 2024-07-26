defmodule LivescriptTest do
  use ExUnit.Case

  describe "split_at_diff" do
    test "add element" do
      first = [1, 2, 3]
      second = [1, 2, 3, 4]
      expected = {[1, 2, 3], [], [4]}
      {common, rest1, rest2} = Livescript.split_at_diff(first, second)
      assert expected == {common, rest1, rest2}
      assert common ++ rest1 == first
      assert common ++ rest2 == second
    end

    test "change last element" do
      first = [1, 2, 3]
      second = [1, 2, 4]
      expected = {[1, 2], [3], [4]}
      {common, rest1, rest2} = Livescript.split_at_diff(first, second)
      assert expected == {common, rest1, rest2}
      assert common ++ rest1 == first
      assert common ++ rest2 == second
    end

    test "remove element" do
      first = [1, 2, 3]
      second = [1, 2]
      expected = {[1, 2], [3], []}
      {common, rest1, rest2} = Livescript.split_at_diff(first, second)
      assert expected == {common, rest1, rest2}
      assert common ++ rest1 == first
      assert common ++ rest2 == second
    end

    test "add element at the beginning" do
      first = [1, 2, 3]
      second = [4, 1, 2, 3]
      expected = {[], [1, 2, 3], [4, 1, 2, 3]}
      {common, rest1, rest2} = Livescript.split_at_diff(first, second)
      assert expected == {common, rest1, rest2}
      assert common ++ rest1 == first
      assert common ++ rest2 == second
    end

    test "remove element at the beginning" do
      first = [1, 2, 3]
      second = [2, 3]
      expected = {[], [1, 2, 3], [2, 3]}
      {common, rest1, rest2} = Livescript.split_at_diff(first, second)
      assert expected == {common, rest1, rest2}
      assert common ++ rest1 == first
      assert common ++ rest2 == second
    end

    test "change element in the middle" do
      first = [1, 2, 3]
      second = [1, 4, 3]
      expected = {[1], [2, 3], [4, 3]}
      {common, rest1, rest2} = Livescript.split_at_diff(first, second)
      assert expected == {common, rest1, rest2}
      assert common ++ rest1 == first
      assert common ++ rest2 == second
    end
  end
end
