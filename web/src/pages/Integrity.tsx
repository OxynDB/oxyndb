import { useCallback, useEffect, useState } from 'react'
import { createCheckpoint, exportLedgerUrl, getBranches, getIntegrity, type Branch, type IntegrityReport } from '../api'

// Ledger integrity: checks a branch's Schema Ledger against its checkpoint
// anchors — kept outside the database — and creates new checkpoints.
export default function Integrity() {
  const [branches, setBranches] = useState<Branch[]>([])
  const [branch, setBranch] = useState('main')
  const [report, setReport] = useState<IntegrityReport | null>(null)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  const [msg, setMsg] = useState('')

  useEffect(() => { getBranches().then(setBranches).catch(() => {}) }, [])

  const verify = useCallback(async () => {
    setBusy(true); setErr('')
    try { setReport(await getIntegrity(branch)) }
    catch (e) { setReport(null); setErr((e as Error).message) }
    finally { setBusy(false) }
  }, [branch])

  useEffect(() => { setMsg(''); verify() }, [verify])

  const checkpoint = async () => {
    setBusy(true); setErr(''); setMsg('')
    try {
      const r = await createCheckpoint(branch)
      setMsg(r.checkpoint
        ? `Checkpoint #${r.checkpoint.checkpoint_id} anchored ledger ids ${r.checkpoint.from_id}–${r.checkpoint.to_id} (${r.checkpoint.entry_count} entries).`
        : 'Nothing new to checkpoint.')
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
    verify()
  }

  const options = branches.length ? branches : ([{ name: 'main' }] as Branch[])
  const stat = (label: string, value: number) => (
    <div className="panel" style={{ padding: '10px 14px', minWidth: 140 }}>
      <div className="muted" style={{ fontSize: 12 }}>{label}</div>
      <div style={{ fontSize: 22, fontWeight: 700 }}>{value}</div>
    </div>
  )

  return (
    <div className="fade-up">
      <h1>Ledger integrity</h1>
      <p className="lead" style={{ marginTop: -2 }}>
        Checkpoints anchor the ledger outside the database, so rewritten, deleted or wiped history is caught — even when
        someone could edit the database itself. Anyone can re-check independently with the open-source <code>vdb-verify</code>.
      </p>

      <div className="row" style={{ flexWrap: 'wrap', gap: 10 }}>
        <span className="muted" style={{ fontSize: 13 }}>Branch</span>
        <select value={branch} onChange={e => setBranch(e.target.value)}>
          {options.map(b => <option key={b.name} value={b.name}>{b.name}</option>)}
        </select>
        <button className="ghost" onClick={verify} disabled={busy}>{busy ? '…' : 'Verify now'}</button>
        <button className="primary" onClick={checkpoint} disabled={busy}>Create checkpoint</button>
        <a className="btn ghost" href={exportLedgerUrl(branch)} download={`${branch}-ledger.jsonl`}>Export (JSONL)</a>
      </div>

      {err && <div className="err">{err}</div>}
      {msg && <div className="muted" style={{ marginTop: 10 }}>{msg}</div>}

      {report && (
        <div style={{ marginTop: 18 }}>
          <div className="row" style={{ gap: 12, alignItems: 'center' }}>
            <span className={'lg-status ' + (report.intact ? 'APPLIED' : 'BLOCKED')} style={{ fontSize: 15 }}>
              {report.intact ? 'INTACT' : 'TAMPERED'}
            </span>
            <span className="muted">
              {report.intact
                ? 'Every anchored entry still matches its anchor.'
                : 'The ledger no longer matches what was anchored — see the problems below.'}
            </span>
          </div>

          <div className="row" style={{ flexWrap: 'wrap', gap: 10, marginTop: 14 }}>
            {stat('Ledger entries', report.rows)}
            {stat('Hash-chained', report.chained_rows)}
            {stat('Checkpoints', report.checkpoints)}
            {stat('Anchored entries', report.anchored_rows)}
            {stat('Not yet anchored', report.unanchored_rows)}
          </div>

          {report.problems.length > 0 && (
            <div className="panel" style={{ marginTop: 14 }}>
              <h3 style={{ marginTop: 0 }}>Problems</h3>
              <ul style={{ margin: 0, paddingLeft: 18 }}>
                {report.problems.map((p, i) => <li key={i} className="err" style={{ margin: '4px 0' }}>{p}</li>)}
              </ul>
            </div>
          )}
          {report.notes.length > 0 && (
            <div className="panel" style={{ marginTop: 14 }}>
              <h3 style={{ marginTop: 0 }}>Notes</h3>
              <ul style={{ margin: 0, paddingLeft: 18 }}>
                {report.notes.map((n, i) => <li key={i} className="muted" style={{ margin: '4px 0' }}>{n}</li>)}
              </ul>
            </div>
          )}
        </div>
      )}
    </div>
  )
}
