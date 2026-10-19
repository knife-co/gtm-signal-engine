-- Extra job-title rule added during P3 (the rest come from the P2 schema).
insert into title_function_map (priority, pattern, job_function, note) values
(105, 'demand gen', 'Demand Generation', 'added after reviewing unmapped titles')
on conflict (priority) do nothing;
