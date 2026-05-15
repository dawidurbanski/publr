import { defineConfig } from 'vite';
import fs from 'fs';
import path from 'path';

const MIME = {
    '.css': 'text/css',
    '.js': 'application/javascript',
    '.svg': 'image/svg+xml',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.woff2': 'font/woff2',
};

export default defineConfig({
    publicDir: '../zig-out/browser',
    server: {
        headers: {
            'Cross-Origin-Opener-Policy': 'same-origin',
            // 'credentialless' over 'require-corp' so cross-origin assets without
            // a CORP header (e.g. gravatar.com avatars) still load, while keeping
            // cross-origin isolation available for SharedArrayBuffer if needed.
            'Cross-Origin-Embedder-Policy': 'credentialless'
        }
    },
    plugins: [{
        name: 'serve-static',
        configureServer(server) {
            server.middlewares.use((req, res, next) => {
                if (!req.url?.startsWith('/static/')) return next();
                const filePath = path.resolve(__dirname, '..', req.url.slice(1));
                if (!fs.existsSync(filePath)) return next();
                const ext = path.extname(filePath);
                res.setHeader('Content-Type', MIME[ext] || 'application/octet-stream');
                fs.createReadStream(filePath).pipe(res);
            });
        }
    }]
});
