'use strict';
// Plain words for the emergency-unlock typing challenge (layer 4).
const crypto = require('crypto');

const WORDS = `
anchor autumn balance banner basket beacon blanket border bottle branch breeze bridge bright bucket
cabin candle canvas carpet castle cellar charcoal circle climate cobalt copper corner cotton county
crystal current custom dancer desert detail dinner divide doctor dollar donkey drawer driver eagle
easel effort elbow empire engine evening fabric falcon farmer feather fence fiction filter finger
forest fossil frozen garden gentle glacier global gravel guitar hammer harbor harvest helmet hollow
honest horizon humble hunter island jacket jungle kettle kitten ladder lantern layer legend lemon
letter lizard lumber magnet mammal marble meadow melody mirror modest morning mosaic motion napkin
narrow nature needle network noble number object ocean office orange orbit outline oxygen paddle
palace pencil pepper planet pocket poetry powder prairie puzzle quarter quiet rabbit radius random
ribbon riddle rocket rubber saddle salmon sandal season shadow signal silver singer sketch slogan
socket spider spiral spring statue stream studio summit sunset switch symbol tablet talent temple
thunder ticket timber tissue tomato tunnel turtle umbrella valley velvet vessel violin voyage walnut
wander window winter wizard wonder yellow zipper
`.trim().split(/\s+/);

function challenge(n = 50) {
  const out = [];
  for (let i = 0; i < n; i++) out.push(WORDS[crypto.randomInt(WORDS.length)]);
  return out.join(' ');
}

module.exports = { challenge };
