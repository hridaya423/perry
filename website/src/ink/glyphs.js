// The brushed "perry" wordmark: centerlines + pressure, in letter units.
// x-height top is y = 0, baseline is y = 100. Brush base radius is BRUSH.

export const BRUSH = 15.5;

const P = [
  { d: 'M16,13 C16,50 16,110 16,164', p: [[0, 0.8], [0.05, 1.08], [0.7, 1], [0.93, 0.9], [1, 0.66]] },
  { d: 'M17,30 C24,9 42,2 56,2 C78,2 90,24 90,50 C90,78 75,99 53,99 C39,99 27,93 19,82', p: [[0, 0.9], [0.16, 0.95], [0.45, 1.1], [0.8, 0.96], [1, 0.74]] },
];

const E = [
  { d: 'M10,52 C32,53 60,53 84,49 C86,22 68,2 46,2 C22,2 7,24 7,53 C7,82 26,100 50,100 C65,100 77,94 87,83', p: [[0, 0.56], [0.17, 0.7], [0.3, 1.04], [0.82, 1], [1, 0.74]] },
];

// The r shoulder ends in a ball terminal; the eye lives inside it.
const R = [
  { d: 'M15,15 C15,40 15,70 15,101', p: [[0, 0.86], [0.08, 1.08], [0.92, 1.02], [1, 0.92]] },
  { d: 'M15,38 C19,15 31,5 48,4 C57,4 64,8 68,15', p: [[0, 0.88], [0.38, 0.92], [0.68, 1.1], [0.88, 1.7], [1, 1.95]] },
];

const Y = [
  { d: 'M12,-4 C12,24 11,48 13,64 C16,90 30,100 49,100 C67,100 83,88 83,60', p: [[0, 0.88], [0.07, 1.06], [0.6, 0.98], [1, 0.86]] },
  { d: 'M83,-4 C83,40 83,90 83,124 C83,152 66,166 42,165 C30,164 19,158 10,149', p: [[0, 0.88], [0.05, 1.08], [0.55, 1], [0.86, 0.82], [1, 0.46]] },
];

export const LETTERS = [
  { strokes: P, rot: -0.02, dy: 0 },
  { strokes: E, rot: 0.035, dy: -3 },
  { strokes: R, eye: true, rot: -0.03, dy: 2 },
  { strokes: R, eye: true, rot: 0.045, dy: -4 },
  { strokes: Y, rot: -0.025, dy: 1 },
];

// Gap between ink extents of neighbouring letters (letter units). Optical, tuned by eye.
export const GAPS = [9, 8, 7, 6];
