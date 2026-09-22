# awk -f aggregate.awk passes/raw-*/*.log
BEGIN { print "leg,stage,mean_ms,blocks" }
/^GPU_PROFILE.*stage=/ {
    split(FILENAME, path, "/")
    leg = ""
    for (i in path) if (path[i] ~ /^raw-/) leg = substr(path[i], 5)
    split($4, stage, "=")
    split($5, value, "=")
    key = leg "," stage[2]
    total[key] += value[2]
    count[key]++
}
END {
    for (key in total)
        printf "%s,%.4f,%d\n", key, total[key] / count[key], count[key]
}
