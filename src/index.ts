#!/usr/bin/env node

/**
 * Copyright 2025 LY Corporation
 *
 * LINE Corporation licenses this file to you under the Apache License,
 * version 2.0 (the "License"); you may not use this file except in compliance
 * with the License. You may obtain a copy of the License at:
 *
 *   https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations
 * under the License.
 */
import { createServer } from "node:http";
import { serveStdio } from "@modelcontextprotocol/server/stdio";
import { createMcpHandler, McpServer } from "@modelcontextprotocol/server";
import {
  hostHeaderValidation,
  originValidation,
  toNodeHandler,
} from "@modelcontextprotocol/node";
import * as line from "@line/bot-sdk";
import { LINE_BOT_MCP_SERVER_VERSION, USER_AGENT } from "./version.js";
import CancelRichMenuDefault from "./tools/cancelRichMenuDefault.js";
import PushTextMessage from "./tools/pushTextMessage.js";
import PushFlexMessage from "./tools/pushFlexMessage.js";
import BroadcastTextMessage from "./tools/broadcastTextMessage.js";
import BroadcastFlexMessage from "./tools/broadcastFlexMessage.js";
import GetProfile from "./tools/getProfile.js";
import GetMessageQuota from "./tools/getMessageQuota.js";
import GetRichMenuList from "./tools/getRichMenuList.js";
import DeleteRichMenu from "./tools/deleteRichMenu.js";
import SetRichMenuDefault from "./tools/setRichMenuDefault.js";
import CreateRichMenu from "./tools/createRichMenu.js";
import GetFollowerIds from "./tools/getFollowerIds.js";
import GetGroupSummary from "./tools/getGroupSummary.js";

if (!process.env.CHANNEL_ACCESS_TOKEN) {
  console.error("Please set CHANNEL_ACCESS_TOKEN");
  process.exit(1);
}

const channelAccessToken = process.env.CHANNEL_ACCESS_TOKEN;
const destinationId = process.env.DESTINATION_USER_ID || "";
const messagingApiBaseUrl = process.env.LINE_MESSAGING_API_BASE_URL;

const lineBotClient = line.LineBotClient.fromChannelAccessToken({
  channelAccessToken: channelAccessToken,
  apiBaseURL: messagingApiBaseUrl,
  defaultHeaders: {
    "User-Agent": USER_AGENT,
  },
});

function createLineBotServer() {
  const server = new McpServer({
    name: "line-bot",
    version: LINE_BOT_MCP_SERVER_VERSION,
  });

  new PushTextMessage(lineBotClient, destinationId).register(server);
  new PushFlexMessage(lineBotClient, destinationId).register(server);
  new BroadcastTextMessage(lineBotClient).register(server);
  new BroadcastFlexMessage(lineBotClient).register(server);
  new GetProfile(lineBotClient, destinationId).register(server);
  new GetMessageQuota(lineBotClient).register(server);
  new GetRichMenuList(lineBotClient).register(server);
  new DeleteRichMenu(lineBotClient).register(server);
  new SetRichMenuDefault(lineBotClient).register(server);
  new CancelRichMenuDefault(lineBotClient).register(server);
  new CreateRichMenu(lineBotClient).register(server);
  new GetFollowerIds(lineBotClient).register(server);
  new GetGroupSummary(lineBotClient).register(server);

  return server;
}

const transport = process.env.MCP_TRANSPORT || "http";

if (transport === "stdio") {
  void serveStdio(createLineBotServer, {
    onerror(error) {
      console.error("MCP stdio server error:", error);
    },
  });
} else if (transport === "http") {
  const port = Number(process.env.PORT || "3000");
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    console.error("PORT must be an integer between 1 and 65535.");
    process.exit(1);
  }

  const host = process.env.HOST || "127.0.0.1";
  const handler = createMcpHandler(createLineBotServer);
  const nodeHandler = toNodeHandler(handler, {
    onerror(error) {
      console.error("MCP HTTP server error:", error);
    },
  });
  const allowedHostnames = ["localhost", "127.0.0.1", "[::1]", "centermcp.com"];
  const validateHost = hostHeaderValidation(allowedHostnames);
  const validateOrigin = originValidation(allowedHostnames);
  const httpServer = createServer((request, response) => {
    if (
      !validateHost(request, response) ||
      !validateOrigin(request, response)
    ) {
      return;
    }
    if (request.url?.split("?", 1)[0] === "/healthz") {
      response.writeHead(200, { "Content-Type": "text/plain" });
      response.end("ok\n");
      return;
    }
    if (request.url?.split("?", 1)[0] !== "/mcp") {
      response.writeHead(404);
      response.end();
      return;
    }
    void nodeHandler(request, response);
  });

  httpServer.listen(port, host, () => {
    console.error(
      `MCP Streamable HTTP server listening on http://${host}:${port}/mcp`,
    );
  });

  const shutdown = () => {
    httpServer.close();
    void handler.close();
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
} else {
  console.error("MCP_TRANSPORT must be 'http' or 'stdio'.");
  process.exit(1);
}
