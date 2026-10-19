-- p3_tool_added_signals_view (applied 2026-10-13)
create or replace view tool_added_signals as
select s.company_name, s.domain, s.evidence->>'tool' tool, s.evidence->>'category' category,
       s.detected_at, s.expires_at, s.who, s.angle, s.channel,
       s.evidence->'evidence' as proof, s.evidence->>'not_seen_at' as not_seen_at
from signals s where s.signal_type = 'tool_added' and s.expires_at > now()
order by s.detected_at desc;
