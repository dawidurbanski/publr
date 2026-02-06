import { defineConfig } from 'vite';

export default defineConfig({
    publicDir: '../zig-out/browser',
    server: {
        headers: {
            'Cross-Origin-Opener-Policy': 'same-origin',
            'Cross-Origin-Embedder-Policy': 'require-corp'
        }
    }
});
