import { createPrompt, useState, useKeypress, usePrefix, usePagination, useMemo, isEnterKey, isSpaceKey, isUpKey, isDownKey, isTabKey, makeTheme } from '@inquirer/core';
import chalk from 'chalk';

const BOUNDARY = new Set([' ', '-', '_', '/', '.', ':', '+']);
const APT_NAME = /^[a-z0-9][a-z0-9+.-]*$/;

function subsequenceScore(query, text) {
  let best = -1;
  for (let start = text.indexOf(query[0]); start !== -1; start = text.indexOf(query[0], start + 1)) {
    let position = start;
    let previous = start - 1;
    let score = 0;
    let ok = true;
    for (let i = 0; i < query.length; i += 1) {
      const found = i === 0 ? start : text.indexOf(query[i], position);
      if (found === -1) {
        ok = false;
        break;
      }
      score += 10;
      if (found === previous + 1) score += 14;
      if (found === 0 || BOUNDARY.has(text[found - 1])) score += 10;
      previous = found;
      position = found + 1;
    }
    if (!ok) continue;
    const span = previous - start + 1;
    if (span > query.length * 2 + 3) continue;
    score -= (span - query.length) * 3 + start;
    if (score > best) best = score;
  }
  return best;
}

export function fuzzyScore(rawQuery, rawText) {
  const query = rawQuery.toLowerCase();
  const text = rawText.toLowerCase();
  if (!query) return 0;
  if (!text) return -1;
  const at = text.indexOf(query);
  if (at !== -1) {
    let score = 200 + query.length * 10 - at * 2;
    if (at === 0) score += 80;
    else if (BOUNDARY.has(text[at - 1])) score += 40;
    if (text.length === query.length) score += 200;
    return score;
  }
  if (query.length < 2) return -1;
  return subsequenceScore(query, text);
}

export function scoreItem(query, item) {
  if (!query) return 0;
  const idScore = fuzzyScore(query, item.id);
  const labelScore = fuzzyScore(query, item.label);
  let keywordScore = -1;
  for (const word of (item.keywords ?? '').split(/\s+/)) {
    if (word) keywordScore = Math.max(keywordScore, fuzzyScore(query, word));
  }
  const groupScore = fuzzyScore(query, item.group ?? '');
  const candidates = [
    idScore >= 0 ? idScore * 1.3 : -1,
    labelScore >= 0 ? labelScore * 1.2 : -1,
    keywordScore >= 0 ? keywordScore * 0.9 : -1,
    groupScore >= 0 ? groupScore * 0.5 : -1
  ];
  const best = Math.max(...candidates);
  if (best < 0) return -1;
  return item.id === query.toLowerCase() ? best + 1000 : best;
}

export function filterItems(query, items) {
  const trimmed = query.trim();
  if (!trimmed) return items.slice();
  return items
    .map((item, order) => ({ item, order, score: scoreItem(trimmed, item) }))
    .filter((entry) => entry.score >= 0)
    .sort((a, b) => b.score - a.score || a.order - b.order)
    .map((entry) => entry.item);
}

export function orderByGroup(items) {
  const groups = [...new Set(items.map((item) => item.group))];
  return items
    .map((item, order) => ({ item, order }))
    .sort((a, b) => groups.indexOf(a.item.group) - groups.indexOf(b.item.group) || a.order - b.order)
    .map((entry) => entry.item);
}

function truncate(text, width) {
  return text.length > width ? `${text.slice(0, width - 1)}…` : text;
}

const EXTRA_GROUP = 'Extra apt package';

export const pickTools = createPrompt((config, done) => {
  const { items, pageSize = 12 } = config;
  const theme = makeTheme(config.theme);
  const [status, setStatus] = useState('idle');
  const [query, setQuery] = useState('');
  const [active, setActive] = useState(0);
  const [selected, setSelected] = useState(config.selected ?? []);
  const [extras, setExtras] = useState(config.extras ?? []);
  const prefix = usePrefix({ status, theme });

  const knownIds = useMemo(() => new Set(items.map((item) => item.id)), [items]);

  const rows = useMemo(() => {
    const pool = [
      ...items,
      ...extras.map((pkg) => ({ id: `apt:${pkg}`, label: pkg, group: EXTRA_GROUP, keywords: 'apt package distro extra', extra: pkg }))
    ];
    const matches = query.trim() ? filterItems(query, pool) : orderByGroup(pool);
    const candidate = query.trim().toLowerCase();
    const canAdd = APT_NAME.test(candidate) && !knownIds.has(candidate) && !extras.includes(candidate);
    return canAdd ? [...matches, { id: `add:${candidate}`, add: candidate, label: candidate, group: '' }] : matches;
  }, [items, extras, query, knownIds]);

  const current = rows[Math.min(active, rows.length - 1)];

  const isSelected = (row) => (row.extra ? extras.includes(row.extra) : selected.includes(row.id));

  function toggle(row) {
    if (!row) return;
    if (row.add) {
      setExtras([...extras, row.add]);
      return;
    }
    if (row.extra) {
      setExtras(extras.filter((pkg) => pkg !== row.extra));
      return;
    }
    setSelected(selected.includes(row.id) ? selected.filter((id) => id !== row.id) : [...selected, row.id]);
  }

  function syncLine(rl, text) {
    rl.clearLine(0);
    rl.write(text);
  }

  useKeypress((key, rl) => {
    if (isEnterKey(key)) {
      if (current?.add) {
        toggle(current);
        syncLine(rl, '');
        setQuery('');
        setActive(0);
        return;
      }
      setStatus('done');
      done({ selected, extras });
      return;
    }
    if (isSpaceKey(key) || isTabKey(key)) {
      const wasAdd = Boolean(current?.add);
      toggle(current);
      if (wasAdd) {
        syncLine(rl, '');
        setQuery('');
        setActive(0);
      } else {
        syncLine(rl, query);
        if (isTabKey(key) && rows.length) setActive((Math.min(active, rows.length - 1) + 1) % rows.length);
      }
      return;
    }
    if (isUpKey(key, ['emacs']) || isDownKey(key, ['emacs'])) {
      syncLine(rl, query);
      if (rows.length) {
        const offset = isUpKey(key, ['emacs']) ? -1 : 1;
        setActive((Math.min(active, rows.length - 1) + offset + rows.length) % rows.length);
      }
      return;
    }
    if (key.name === 'pageup' || key.name === 'pagedown') {
      syncLine(rl, query);
      const offset = key.name === 'pageup' ? -pageSize : pageSize;
      setActive(Math.max(0, Math.min(rows.length - 1, Math.min(active, rows.length - 1) + offset)));
      return;
    }
    if (key.name === 'escape') {
      syncLine(rl, '');
      setQuery('');
      setActive(0);
      return;
    }
    if (key.name === 'left' || key.name === 'right' || key.name === 'home' || key.name === 'end') {
      syncLine(rl, query);
      return;
    }
    const next = rl.line;
    if (next !== query) {
      setQuery(next);
      setActive(0);
    }
  });

  const total = selected.length + extras.length;
  const namesOf = () => [
    ...selected.map((id) => items.find((item) => item.id === id)?.label ?? id),
    ...extras.map((pkg) => `${pkg} (apt)`)
  ];

  if (status === 'done') {
    const names = namesOf();
    const shown = names.slice(0, 4).join(', ');
    const answer = total === 0 ? 'none' : `${shown}${names.length > 4 ? `, +${names.length - 4} more` : ''}`;
    return `${prefix} ${theme.style.message(config.message, status)} ${theme.style.answer(answer)}`;
  }

  const columns = process.stdout.columns || 100;
  const showGroup = columns >= 72;
  const labelWidth = Math.min(40, Math.max(...rows.map((row) => row.label.length), 12), Math.max(20, columns - 40));

  const page = usePagination({
    items: rows,
    active: Math.min(active, Math.max(rows.length - 1, 0)),
    renderItem({ item, isActive }) {
      if (item.add) {
        const line = `${isActive ? '❯' : ' '} + add "${item.add}" as an extra apt package`;
        return isActive ? chalk.cyan(line) : chalk.dim(line);
      }
      const on = isSelected(item);
      const box = on ? chalk.green('◉') : chalk.dim('◯');
      const label = truncate(item.label, labelWidth).padEnd(labelWidth);
      const group = showGroup && item.group ? `  ${chalk.dim(item.group)}` : '';
      const line = `${isActive ? chalk.cyan('❯') : ' '} ${box} ${isActive ? chalk.cyan(label) : label}${group}`;
      return line;
    },
    pageSize,
    loop: false
  });

  const header = `${prefix} ${theme.style.message(config.message, status)} ${chalk.dim('›')} ${query}`;

  let info = '';
  if (current && !current.add) {
    const meta = [`id: ${current.extra ? current.label : current.id}`];
    if (current.requires?.length) meta.push(`needs ${current.requires.join(', ')}`);
    if (current.keywords) meta.push(current.keywords);
    info = chalk.dim(truncate(meta.join(' · '), columns - 4));
  }
  const counts = chalk.dim(`${rows.filter((row) => !row.add).length} shown`) + chalk.dim(' · ') + (total ? chalk.green(`${total} selected`) : chalk.dim('0 selected'));
  const help = chalk.dim('type to filter · ↑↓ move · space toggle · enter confirm · ctrl-u clear');
  const empty = rows.length === 0 ? chalk.yellow('  No matches.') : '';

  const body = [empty || page, ' ', counts, info, help].filter(Boolean).join('\n');
  return [header, body];
});
