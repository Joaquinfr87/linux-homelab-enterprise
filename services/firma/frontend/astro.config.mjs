import { defineConfig } from "astro/config";

export default defineConfig({
  outDir: "./dist",
  server: {
    host: "0.0.0.0",
    port: 4321
  },
  vite: {
    server: {
      host: "0.0.0.0",
      proxy: {
        "/api": "http://127.0.0.1:5000",
      },
    },
  },
});
