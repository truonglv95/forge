/**
 * Forge tool-loop round-trip test using z-ai SDK as the LLM.
 * Simulates the conversation flow:
 *   1. user text -> appendToolUserText
 *   2. assistant tool_call -> appendToolCall
 *   3. tool result -> appendToolResult
 *   4. assistant final text -> output
 *
 * This mirrors what forge/packages/ai/src/agent/loop.zig does, but in JS
 * for quick verification without needing a built forge binary.
 */
const ZAI = require('/home/z/.bun/install/global/node_modules/z-ai-web-dev-sdk').default;

const TOOLS = [
  {
    name: 'read_file',
    description: 'Read a file from the workspace.',
    parameters: {
      type: 'object',
      properties: { path: { type: 'string', description: 'File path to read.' } },
      required: ['path'],
    },
  },
  {
    name: 'write_file',
    description: 'Write content to a file.',
    parameters: {
      type: 'object',
      properties: {
        path: { type: 'string' },
        content: { type: 'string' },
      },
      required: ['path', 'content'],
    },
  },
];

function toolDeclarationsJson() {
  return JSON.stringify(TOOLS);
}

// Anthropic-style message builders (mirrors anthropic/provider.zig appendTool*)
function appendUserText(conversation, text) {
  conversation.push({
    role: 'user',
    content: [{ type: 'text', text }],
  });
}

function appendToolCall(conversation, id, name, input) {
  conversation.push({
    role: 'assistant',
    content: [{ type: 'tool_use', id, name, input }],
  });
}

function appendToolResult(conversation, toolUseId, content) {
  conversation.push({
    role: 'user',
    content: [{ type: 'tool_result', tool_use_id: toolUseId, content }],
  });
}

async function main() {
  console.log('=== Forge Tool-Loop Round-Trip Test (z-ai SDK) ===\n');

  const zai = await ZAI.create();
  const conversation = [];

  // Step 1: User asks to read a file and write a summary
  appendUserText(conversation, 'Read the file README.md, then write a 1-line summary to SUMMARY.txt.');
  console.log('Step 1: user message appended');

  // Step 2: Simulate model emitting a tool_use (in real forge, this comes from LLM)
  // We ask the LLM to choose a tool call.
  const toolChoiceCompletion = await zai.chat.completions.create({
    messages: [
      {
        role: 'assistant',
        content:
          'You are an agent. Pick ONE tool to call given the user request. Reply with ONLY JSON like {"tool":"read_file","args":{"path":"README.md"}}. No markdown.',
      },
      { role: 'user', content: 'Read the file README.md, then write a 1-line summary to SUMMARY.txt.' },
    ],
    thinking: { type: 'disabled' },
  });

  const choiceText = toolChoiceCompletion.choices[0].message.content.trim();
  console.log('Step 2: model chose tool call ->', choiceText);

  let parsed;
  try {
    // Strip markdown code fences if present
    const cleaned = choiceText.replace(/^```json\s*|\s*```$/g, '').trim();
    parsed = JSON.parse(cleaned);
  } catch (e) {
    console.error('FAIL: model did not return valid JSON tool call');
    process.exit(1);
  }

  // Append the tool_use block to conversation (mirrors appendToolCallImpl)
  const toolUseId = 'toolu_001';
  appendToolCall(conversation, toolUseId, parsed.tool, parsed.args);

  // Step 3: Simulate tool execution and append tool_result
  const fakeFileContent = '# Forge\n\nA native Zig AI coding assistant with CLI, TUI, and IDE surfaces.';
  appendToolResult(conversation, toolUseId, fakeFileContent);
  console.log('Step 3: tool_result appended (fake README.md content)');

  // Step 4: Ask model to produce final answer given the conversation history
  const finalCompletion = await zai.chat.completions.create({
    messages: [
      {
        role: 'assistant',
        content:
          'You are an agent. Given the tool_result, decide the next action. Reply with ONLY JSON like {"tool":"write_file","args":{"path":"SUMMARY.txt","content":"..."}} or {"done":true,"answer":"..."}.',
      },
      {
        role: 'user',
        content:
          'Conversation so far (JSON): ' +
          JSON.stringify(conversation) +
          '\n\nNow decide the next step.',
      },
    ],
    thinking: { type: 'disabled' },
  });

  const finalText = finalCompletion.choices[0].message.content.trim();
  console.log('Step 4: model final decision ->', finalText);

  let finalParsed;
  try {
    const cleaned = finalText.replace(/^```json\s*|\s*```$/g, '').trim();
    finalParsed = JSON.parse(cleaned);
  } catch (e) {
    console.error('FAIL: model did not return valid JSON for final step');
    process.exit(1);
  }

  if (finalParsed.tool === 'write_file' && finalParsed.args.path === 'SUMMARY.txt') {
    console.log('\nPASS: Tool-loop round-trip succeeded!');
    console.log('  - User text appended:', conversation[0].role === 'user');
    console.log('  - Tool call appended:', conversation[1].content[0].type === 'tool_use');
    console.log('  - Tool result appended:', conversation[2].content[0].type === 'tool_result');
    console.log('  - Final write_file emitted with path SUMMARY.txt');
    console.log('  - Summary content:', finalParsed.args.content);
    console.log('\nUsage: input=' + (toolChoiceCompletion.usage?.prompt_tokens || '?') +
      '+' + (finalCompletion.usage?.prompt_tokens || '?') +
      ', output=' + (toolChoiceCompletion.usage?.completion_tokens || '?') +
      '+' + (finalCompletion.usage?.completion_tokens || '?') + ' tokens');
  } else {
    console.error('FAIL: unexpected final action', finalParsed);
    process.exit(1);
  }
}

main().catch((err) => {
  console.error('Test crashed:', err);
  process.exit(2);
});
