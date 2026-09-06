import { defineConfig } from 'vitest/config';
export default defineConfig({
  // Rapier 0.17's Node package entry incorrectly mixes CJS and ESM; use its actual ESM bundle everywhere.
  resolve:{alias:{'@dimforge/rapier3d-compat':'@dimforge/rapier3d-compat/rapier.es.js'}},
  server:{host:'0.0.0.0',port:5173},
  build:{chunkSizeWarningLimit:2500},
  test:{include:['tests/**/*.test.ts'],testTimeout:90000}
});
