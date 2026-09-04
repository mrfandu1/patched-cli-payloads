// Loopback CONNECT proxy for Linux binaries that cannot use Android's DNS resolver.
const http = require("http");
const net = require("net");

const PORT = 18080;
const server = http.createServer((_request, response) => response.writeHead(405).end());

server.on("connect", (request, clientSocket, head) => {
  const [host, rawPort] = request.url.split(":");
  const upstream = net.connect(Number.parseInt(rawPort, 10) || 443, host, () => {
    clientSocket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
    if (head?.length) upstream.write(head);
    upstream.pipe(clientSocket);
    clientSocket.pipe(upstream);
  });
  upstream.on("error", () => clientSocket.destroy());
  clientSocket.on("error", () => upstream.destroy());
});

server.on("error", (error) => {
  if (error.code === "EADDRINUSE") process.exit(0);
  console.error(error);
  process.exit(1);
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`local proxy listening on 127.0.0.1:${PORT}`);
});

