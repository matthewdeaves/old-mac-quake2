import csv,sys,statistics
for path in sys.argv[1:]:
    rows=list(csv.DictReader(open(path)))
    t0=float(rows[0]['end_ms'])
    data=[]
    for i in range(1,len(rows)):
        r=rows[i]; end=float(r['end_ms']); start=float(r['start_ms']); prev=float(rows[i-1]['end_ms'])
        if end-t0>5000:
            data.append((end-t0,end-prev,end-start,float(r['audio_lock_ms'])))
    def stats(v):
        s=sorted(v)
        return 'median %.3f p95 %.3f p99 %.3f max %.3f'%tuple([statistics.median(s),s[int(.95*(len(s)-1))],s[int(.99*(len(s)-1))],max(s)])
    print(path,len(data), 'frames')
    print('interval',stats([r[1] for r in data]))
    print('swap',stats([r[2] for r in data]))
    print('audio lock',stats([r[3] for r in data]))
    print('over25ms',sum(r[1]>25 for r in data),'over50ms',sum(r[1]>50 for r in data))
    print('worst',sorted(data,key=lambda r:r[1],reverse=True)[:12])
