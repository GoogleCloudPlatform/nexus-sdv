// Static image imports resolve to this in component tests. It mirrors the shape
// of a real static import because next/image needs width and height — a plain
// string stub would fail to render.
module.exports = { src: '/test-file-stub.png', height: 24, width: 24 };
