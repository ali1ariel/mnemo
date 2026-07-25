defmodule MnemoWeb.PageController do
  use MnemoWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
