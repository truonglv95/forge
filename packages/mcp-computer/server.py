import asyncio
import io
import base64

from mcp.server import Server, NotificationOptions
from mcp.server.models import InitializationOptions
from mcp.server.stdio import stdio_server
import mcp.types as types

import pyautogui
import PIL.ImageGrab

server = Server("computer-control")

# Disable pyautogui fail-safe or adjust if needed (optional)
# pyautogui.FAILSAFE = True

@server.list_tools()
async def handle_list_tools() -> list[types.Tool]:
    return [
        types.Tool(
            name="take_screenshot",
            description="Take a screenshot of the main screen",
            inputSchema={
                "type": "object",
                "properties": {},
            }
        ),
        types.Tool(
            name="mouse_move",
            description="Move the mouse to a specific coordinate",
            inputSchema={
                "type": "object",
                "properties": {
                    "x": {"type": "integer", "description": "X coordinate"},
                    "y": {"type": "integer", "description": "Y coordinate"}
                },
                "required": ["x", "y"]
            }
        ),
        types.Tool(
            name="mouse_click",
            description="Click the mouse",
            inputSchema={
                "type": "object",
                "properties": {
                    "button": {"type": "string", "enum": ["left", "right", "middle"], "default": "left"}
                }
            }
        ),
        types.Tool(
            name="keyboard_type",
            description="Type text on the keyboard",
            inputSchema={
                "type": "object",
                "properties": {
                    "text": {"type": "string", "description": "Text to type"}
                },
                "required": ["text"]
            }
        ),
        types.Tool(
            name="keyboard_press",
            description="Press a specific key (e.g. 'enter', 'tab')",
            inputSchema={
                "type": "object",
                "properties": {
                    "key": {"type": "string", "description": "Key to press"}
                },
                "required": ["key"]
            }
        )
    ]

@server.call_tool()
async def handle_call_tool(
    name: str, arguments: dict | None
) -> list[types.TextContent | types.ImageContent | types.EmbeddedResource]:
    if arguments is None:
        arguments = {}
        
    if name == "take_screenshot":
        img = PIL.ImageGrab.grab()
        buffered = io.BytesIO()
        img.save(buffered, format="PNG")
        img_str = base64.b64encode(buffered.getvalue()).decode()
        
        return [
            types.ImageContent(
                type="image",
                data=img_str,
                mimeType="image/png"
            )
        ]
        
    elif name == "mouse_move":
        x = arguments["x"]
        y = arguments["y"]
        pyautogui.moveTo(x, y)
        return [types.TextContent(type="text", text=f"Mouse moved to {x}, {y}")]
        
    elif name == "mouse_click":
        button = arguments.get("button", "left")
        pyautogui.click(button=button)
        return [types.TextContent(type="text", text=f"Mouse clicked with {button} button")]
        
    elif name == "keyboard_type":
        text = arguments["text"]
        pyautogui.write(text)
        return [types.TextContent(type="text", text=f"Typed text: {text}")]
        
    elif name == "keyboard_press":
        key = arguments["key"]
        pyautogui.press(key)
        return [types.TextContent(type="text", text=f"Pressed key: {key}")]
        
    raise ValueError(f"Unknown tool: {name}")

async def main():
    # Run the server using standard input/output streams
    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            InitializationOptions(
                server_name="computer-control",
                server_version="0.1.0",
                capabilities=server.get_capabilities(
                    notification_options=NotificationOptions(),
                    experimental_capabilities={},
                ),
            ),
        )

if __name__ == "__main__":
    asyncio.run(main())
