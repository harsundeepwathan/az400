-- Private storage bucket for original resume files (Supabase only).
-- Objects are stored under "<user_id>/<file>" and policies restrict every
-- operation to the owner's folder. Skipped automatically on plain PostgreSQL.
do $$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values (
      'resumes', 'resumes', false, 5242880,
      array['application/pdf', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document']
    )
    on conflict (id) do nothing;

    execute $p$
      create policy "resume files are private to their owner"
      on storage.objects for all to authenticated
      using (bucket_id = 'resumes' and (storage.foldername(name))[1] = (select auth.uid())::text)
      with check (bucket_id = 'resumes' and (storage.foldername(name))[1] = (select auth.uid())::text)
    $p$;
  end if;
end
$$;
