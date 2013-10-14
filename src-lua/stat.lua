stat = stat or {}
stat.records = {}
stat.total = {}

function stat.print()
        local out = {}
        local sum = {}
        for i = 0, 4 do
                if type(stat.records[i]) == "table" then
                        for k, v in pairs(stat.records[i]) do
                                sum[k] = (sum[k] or 0) + v
                        end
                end
        end

        table.insert(out, "statistics:\r\n")

        local ordered_keys = {}
        for k in pairs(sum) do
                table.insert(ordered_keys, k)
        end
        table.sort(ordered_keys)

        for k, key in pairs(ordered_keys) do
                local rps = sum[key] / 5
                local total = stat.total[key]
                local line = string.format("  %-14s { rps:  %-5i, total:  %-11i }\r\n",
                                           key .. ':', rps, total)
                table.insert(out, line)
        end
        return table.concat(out)
end

function stat.clear()
        stat.records = {}
        stat.total = {}
end

function stat.record(rec)
        for i = 4, 1, -1 do
                stat.records[i] = stat.records[i - 1]
        end
        stat.records[0] = rec
        for k, v in pairs(stat.records[0]) do
                stat.total[k] = (stat.total[k] or 0) + v
        end
end