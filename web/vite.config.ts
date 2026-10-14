import { defineConfig } from 'vitest/config';
import solid from 'vite-plugin-solid';

export default defineConfig({
  plugins: [solid()],
  // Relative asset paths, so the build works from any sub-path of a static host.
  base: './',
  server: { port: 5173, strictPort: true },
  test: { environment: 'node', include: ['test/**/*.test.ts'] },
});
