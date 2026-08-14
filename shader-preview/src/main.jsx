import React, { useEffect, useMemo, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { ThinkingOrb, resolvePreset } from 'thinking-orbs';
import { MODE_FRAMES } from 'thinking-orbs/engine';
import './thinking-orb.css';

const ORB_STATES = [
  'working',
  'searching',
  'solving',
  'listening',
  'connecting',
  'weaving',
  'composing',
  'breathing',
  'shaping'
];

const STATUS_MAP = {
  working: { state: 'working', running: true },
  asking: { state: 'listening', running: true },
  done: { state: 'breathing', running: false },
  failed: { state: 'shaping', running: false },
  idle: { state: 'breathing', running: false }
};

function readInitialIdentity() {
  return window.noturcodePreviewState ?? {
    name: 'fidelizare',
    primary: [240, 115, 206],
    secondary: [255, 146, 175],
    state: 'working'
  };
}

function clamp(value, min = 0, max = 1) {
  return Math.min(max, Math.max(min, value));
}

function mix(a, b, amount) {
  return a.map((channel, index) => Math.round(channel + (b[index] - channel) * amount));
}

function colorForInk(primary, secondary, white) {
  const depth = 1 - clamp(white);
  const color = mix(secondary, primary, depth);
  const luminance = 0.42 + depth * 0.58;
  const nearHighlight = clamp((depth - 0.74) / 0.26) * 0.20;
  return color.map((channel) => Math.round(channel * luminance + (255 - channel) * nearHighlight));
}

function rgba(rgb, alpha) {
  return `rgba(${rgb[0]}, ${rgb[1]}, ${rgb[2]}, ${alpha})`;
}

function paintColorFrame(context, frame, primary, secondary) {
  for (const line of frame.lines) {
    context.strokeStyle = rgba(colorForInk(primary, secondary, line.white), line.a ?? 1);
    context.lineWidth = line.w;
    context.beginPath();
    context.moveTo(line.x1, line.y1);
    context.lineTo(line.x2, line.y2);
    context.stroke();
  }

  for (const dot of frame.dots) {
    context.fillStyle = rgba(colorForInk(primary, secondary, dot.white), dot.a ?? 1);
    context.beginPath();
    context.arc(dot.x, dot.y, dot.r, 0, Math.PI * 2);
    context.fill();
  }
}

function ColorThinkingOrb({ state, running, speed, primary, secondary, label }) {
  const canvasRef = useRef(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return undefined;
    const size = 64;
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    const context = canvas.getContext('2d');
    if (!context) return undefined;

    canvas.width = Math.round(size * dpr);
    canvas.height = Math.round(size * dpr);
    const preset = resolvePreset(state, size);
    const draw = (seconds) => {
      context.setTransform(dpr, 0, 0, dpr, 0, 0);
      context.clearRect(0, 0, size, size);
      const frame = MODE_FRAMES[preset.mode](size, seconds * preset.speed * speed, preset.opts);
      paintColorFrame(context, frame, primary, secondary);
    };

    const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (!running || reducedMotion) {
      draw(0.6);
      return undefined;
    }

    let requestID = 0;
    let active = true;
    const tick = (time) => {
      if (!active) return;
      draw(time / 1000);
      requestID = requestAnimationFrame(tick);
    };
    requestID = requestAnimationFrame(tick);
    return () => {
      active = false;
      cancelAnimationFrame(requestID);
    };
  }, [state, running, speed, primary, secondary]);

  return <canvas ref={canvasRef} className="color-orb-canvas" role="img" aria-label={label} />;
}

function ThinkingOrbLab() {
  const [identity, setIdentity] = useState(readInitialIdentity);
  const [orbState, setOrbState] = useState('composing');
  const [running, setRunning] = useState(true);
  const [speed, setSpeed] = useState(1);
  const [followStatus, setFollowStatus] = useState(false);

  useEffect(() => {
    const receiveIdentity = (event) => setIdentity(event.detail);
    window.addEventListener('noturcode:identity', receiveIdentity);
    return () => window.removeEventListener('noturcode:identity', receiveIdentity);
  }, []);

  useEffect(() => {
    if (!followStatus) return;
    const mapped = STATUS_MAP[identity.state] ?? STATUS_MAP.idle;
    setOrbState(mapped.state);
    setRunning(mapped.running);
  }, [followStatus, identity.state]);

  const primaryCSS = useMemo(() => `rgb(${identity.primary.join(' ')})`, [identity.primary]);
  const secondaryCSS = useMemo(() => `rgb(${identity.secondary.join(' ')})`, [identity.secondary]);

  return (
    <div className="orb-lab">
      <div className="orb-lab-copy">
        <span className="orb-kicker">thinking-orbs 0.3.1 / Canvas 2D</span>
        <h2>Official motion.<br />Noturcode color.</h2>
        <p>The left orb is the original package. The right orb uses the same public geometry with a custom color painter.</p>
        <div className="orb-color-pair" aria-label="Current Noturcode color pair">
          <i style={{ background: primaryCSS }} />
          <i style={{ background: secondaryCSS }} />
          <span>{identity.name}</span>
        </div>
      </div>

      <div className="orb-comparison">
        <figure>
          <div className="orb-stage original-orb">
            <ThinkingOrb state={orbState} size={64} theme="dark" speed={speed} paused={!running} />
          </div>
          <figcaption>Package original</figcaption>
        </figure>
        <div className="orb-arrow" aria-hidden="true">&gt;</div>
        <figure>
          <div className="orb-stage custom-orb" style={{ '--orb-glow': primaryCSS }}>
            <ColorThinkingOrb
              state={orbState}
              running={running}
              speed={speed}
              primary={identity.primary}
              secondary={identity.secondary}
              label={`${identity.name}, ${orbState}, ${running ? 'running' : 'paused'}`}
            />
          </div>
          <figcaption>Noturcode custom</figcaption>
        </figure>
      </div>

      <div className="orb-controls">
        <label>
          <span>Orb motion</span>
          <select value={orbState} onChange={(event) => { setOrbState(event.target.value); setFollowStatus(false); }}>
            {ORB_STATES.map((state) => <option key={state} value={state}>{state}</option>)}
          </select>
        </label>
        <label className="orb-toggle">
          <span>Running</span>
          <input type="checkbox" checked={running} onChange={(event) => { setRunning(event.target.checked); setFollowStatus(false); }} />
        </label>
        <label>
          <span>Speed {speed.toFixed(1)}x</span>
          <input type="range" min="0.4" max="2" step="0.1" value={speed} onChange={(event) => setSpeed(Number(event.target.value))} />
        </label>
        <label className="orb-toggle">
          <span>Follow Noturcode state</span>
          <input type="checkbox" checked={followStatus} onChange={(event) => setFollowStatus(event.target.checked)} />
        </label>
      </div>
    </div>
  );
}

createRoot(document.querySelector('#thinking-orb-root')).render(<ThinkingOrbLab />);
