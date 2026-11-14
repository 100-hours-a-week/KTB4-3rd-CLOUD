local events = {
    fastapi = {
        analysis_started = true,
        analysis_succeeded = true,
        analysis_failed = true,
        analysis_timeout = true,
        analysis_stale = true,
    },
    worker = {
        request_published = true,
        request_publish_failed = true,
        result_processed = true,
        result_apply_failed = true,
    },
}

local uuid = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

function sanitize(tag, timestamp, record)
    local stage, service = tag:match("^congestion%.([a-z]+)%.([a-z]+)$")
    local event = record.event
    if (stage ~= "dev" and stage ~= "stg") or not events[service]
        or record.schema ~= "congestion.v1" or type(event) ~= "string"
        or events[service][event] ~= true then
        return -1, timestamp, record
    end

    local id = record.event_id
    if type(id) ~= "string" or not id:match(uuid) then
        return -1, timestamp, record
    end

    local safe = { schema = "congestion.v1", stage = stage, service = service, event = event, event_id = id }
    local duration = record.duration_ms
    if type(duration) == "number" and duration >= 0 and duration <= 3600000 and duration % 1 == 0 then
        safe.duration_ms = duration
    end
    return 2, timestamp, safe
end
