import { useCallback, useEffect, useState } from 'react'
import {
  addPolicyRule, checkPolicy, getBranches, getPolicyEvaluations, getPolicyRules, removePolicyRule, updatePolicyRule,
  type Branch, type PolicyAction, type PolicyCheckResult, type PolicyEvaluation, type PolicyRule,
} from '../api'

// Blackbox policy gate: rules checked on every schema change before it runs.
// A warn rule lets the change through with a notice (SQLSTATE VDB02); a block
// rule refuses it (VDB01). Reading and previewing are open to everyone; changing
// rules needs vdb_admin on the branch.
const emptyDraft = { rule_id: '', command_tag: 'ALTER TABLE', pattern: '', action: 'warn' as PolicyAction, reason: '', hint: '' }

export default function Policies() {
  const [branches, setBranches] = useState<Branch[]>([])
  const [branch, setBranch] = useState('main')
  const [rules, setRules] = useState<PolicyRule[]>([])
  const [evals, setEvals] = useState<PolicyEvaluation[]>([])
  const [err, setErr] = useState('')
  const [busy, setBusy] = useState(false)
  const [sql, setSql] = useState('')
  const [check, setCheck] = useState<PolicyCheckResult | null>(null)
  const [adding, setAdding] = useState(false)
  const [draft, setDraft] = useState(emptyDraft)

  useEffect(() => { getBranches().then(setBranches).catch(() => {}) }, [])

  const load = useCallback(async () => {
    try {
      const [r, e] = await Promise.all([getPolicyRules(branch), getPolicyEvaluations(branch, 20)])
      setRules(r); setEvals(e)
    } catch (e) {
      setRules([]); setEvals([]); setErr((e as Error).message)
    }
  }, [branch])
  useEffect(() => { setErr(''); setCheck(null); load() }, [load])

  const act = async (f: () => Promise<unknown>) => {
    setBusy(true); setErr('')
    try { await f(); await load() } catch (e) { setErr((e as Error).message) } finally { setBusy(false) }
  }

  const runCheck = async () => {
    setBusy(true); setErr('')
    try { setCheck(await checkPolicy(branch, sql)) } catch (e) { setCheck(null); setErr((e as Error).message) } finally { setBusy(false) }
  }

  const add = () => act(async () => {
    await addPolicyRule(branch, {
      rule_id: draft.rule_id.trim(), command_tag: draft.command_tag.trim().toUpperCase(), pattern: draft.pattern || null,
      action: draft.action, reason: draft.reason, hint: draft.hint || null,
    })
    setAdding(false); setDraft(emptyDraft)
  })

  const options = branches.length ? branches : ([{ name: 'main' }] as Branch[])
  const badge = (action: string) => (
    <span className={'lg-status ' + (action === 'block' ? 'BLOCKED' : action === 'allowed' ? 'APPLIED' : 'FLAGGED')}>{action.toUpperCase()}</span>
  )

  return (
    <div className="fade-up">
      <h1>Policies</h1>
      <p className="lead" style={{ marginTop: -2 }}>
        Blackbox checks every schema change against these rules before it runs. <b>Warn</b> lets it through with a notice;{' '}
        <b>block</b> refuses it with SQLSTATE <code>VDB01</code> and records the attempt. Changing rules needs{' '}
        <code>vdb_admin</code> (<code>vdb admin grant &lt;email&gt;</code>).
      </p>

      <div className="row" style={{ flexWrap: 'wrap', gap: 10 }}>
        <span className="muted" style={{ fontSize: 13 }}>Branch</span>
        <select value={branch} onChange={e => setBranch(e.target.value)}>
          {options.map(b => <option key={b.name} value={b.name}>{b.name}</option>)}
        </select>
        <button className="ghost" onClick={() => setAdding(a => !a)} disabled={busy}>{adding ? 'Cancel' : 'Add rule'}</button>
      </div>

      {err && <div className="err">{err}</div>}

      {adding && (
        <div className="panel" style={{ marginTop: 14 }}>
          <h3 style={{ marginTop: 0 }}>New rule</h3>
          <div className="row" style={{ flexWrap: 'wrap', gap: 10 }}>
            <input placeholder="rule-id" value={draft.rule_id} onChange={e => setDraft({ ...draft, rule_id: e.target.value })} style={{ width: 180 }} />
            <input placeholder="Command, e.g. ALTER TABLE" value={draft.command_tag} onChange={e => setDraft({ ...draft, command_tag: e.target.value })} style={{ width: 200 }} />
            <input placeholder="Pattern (regex, optional)" value={draft.pattern} onChange={e => setDraft({ ...draft, pattern: e.target.value })} style={{ width: 240 }} />
            <div className="seg">
              {(['warn', 'block'] as PolicyAction[]).map(a => (
                <button key={a} className={draft.action === a ? 'active' : ''} onClick={() => setDraft({ ...draft, action: a })}>{a}</button>
              ))}
            </div>
          </div>
          <div className="row" style={{ flexWrap: 'wrap', gap: 10, marginTop: 10 }}>
            <input placeholder="Why this rule exists" value={draft.reason} onChange={e => setDraft({ ...draft, reason: e.target.value })} style={{ flex: '1 1 280px' }} />
            <input placeholder="Next step to suggest (optional)" value={draft.hint} onChange={e => setDraft({ ...draft, hint: e.target.value })} style={{ flex: '1 1 280px' }} />
            <button className="primary" onClick={add} disabled={busy || !draft.rule_id || !draft.reason}>Add</button>
          </div>
        </div>
      )}

      <div className="table-wrap" style={{ marginTop: 14 }}>
        <table>
          <thead><tr><th>Rule</th><th>Applies to</th><th>Why</th><th>Action</th><th>On</th><th /></tr></thead>
          <tbody>
            {rules.length === 0 && <tr><td colSpan={6} className="muted">no rules on this branch</td></tr>}
            {rules.map(r => (
              <tr key={r.rule_id} style={{ opacity: r.enabled ? 1 : 0.55 }}>
                <td style={{ whiteSpace: 'nowrap' }}><code>{r.rule_id}</code>{r.builtin && <span className="muted"> · built-in</span>}</td>
                <td>
                  <code className="mono">{r.command_tag}</code>
                  {r.pattern && <div className="muted mono" style={{ fontSize: 12 }}>{r.pattern}</div>}
                </td>
                <td className="muted">{r.reason}</td>
                <td>
                  <div className="seg">
                    {(['warn', 'block'] as PolicyAction[]).map(a => (
                      <button key={a} className={r.action === a ? 'active' : ''} disabled={busy || r.action === a}
                        onClick={() => act(() => updatePolicyRule(branch, r.rule_id, { action: a }))}>{a}</button>
                    ))}
                  </div>
                </td>
                <td>
                  <input type="checkbox" checked={r.enabled} disabled={busy}
                    onChange={e => act(() => updatePolicyRule(branch, r.rule_id, { enabled: e.target.checked }))} />
                </td>
                <td>
                  {!r.builtin && <button className="ghost" disabled={busy} onClick={() => act(() => removePolicyRule(branch, r.rule_id))}>Remove</button>}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="panel" style={{ marginTop: 18 }}>
        <h3 style={{ marginTop: 0 }}>Check a statement</h3>
        <p className="muted" style={{ marginTop: 0 }}>See which rules a schema change would trigger, without running it.</p>
        <textarea rows={3} style={{ width: '100%' }} placeholder="ALTER TABLE orders DROP COLUMN note"
          value={sql} onChange={e => setSql(e.target.value)} />
        <div className="row" style={{ marginTop: 8 }}>
          <button className="primary" onClick={runCheck} disabled={busy || !sql.trim()}>Check</button>
        </div>
        {check && (
          <div style={{ marginTop: 10 }}>
            <div className="muted" style={{ fontSize: 13 }}>Command: <code>{check.command}</code></div>
            {check.matches.length === 0
              ? <div style={{ marginTop: 6 }}>No rule matches — this change would run without a warning.</div>
              : check.matches.map(m => (
                <div key={m.rule_id} style={{ marginTop: 6 }}>
                  {badge(m.action)} <code>{m.rule_id}</code> — {m.reason}
                  <div className="muted" style={{ fontSize: 13 }}>{m.hint}</div>
                </div>
              ))}
          </div>
        )}
      </div>

      <h3 style={{ marginTop: 22 }}>Recent evaluations</h3>
      <div className="table-wrap">
        <table>
          <thead><tr><th>Time (UTC)</th><th>Rule</th><th>Result</th><th>Command</th><th>Actor</th><th>Blackbox entry</th></tr></thead>
          <tbody>
            {evals.length === 0 && <tr><td colSpan={6} className="muted">nothing yet</td></tr>}
            {evals.map(e => (
              <tr key={e.id}>
                <td className="mono muted" style={{ whiteSpace: 'nowrap' }}>{e.at.replace('T', ' ').replace('Z', '')}</td>
                <td><code>{e.rule_id}</code></td>
                <td>{badge(e.action)}</td>
                <td className="mono">{e.command_tag || '—'}</td>
                <td>{e.actor || '—'}</td>
                <td className="mono">{e.blackbox_id ?? '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}
