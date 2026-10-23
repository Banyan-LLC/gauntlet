"""A real SDK peer for the test transport's roundtrip/closure characterization."""
import anyio
from mcp.server.lowlevel import Server
from mcp.server.stdio import stdio_server
from mcp_types import ListToolsResult, Tool


async def list_tools(context, params):
    return ListToolsResult(tools=[Tool(name="probe-tool", inputSchema={"type": "object"})])


async def main():
    server = Server("owned-transport-probe", on_list_tools=list_tools)
    async with stdio_server() as (read, write):
        await server.run(read, write, server.create_initialization_options())


anyio.run(main)
