-- Synchronize the 45 VOTO questions with their existing carta-001..carta-045 rows.
-- UUIDs and slugs are deliberately preserved. Run once in the Supabase SQL editor.

begin;

create temporary table desired_voto_cards (
  position integer primary key,
  slug text unique not null,
  question_text text not null
) on commit drop;

insert into pg_temp.desired_voto_cards (position, slug, question_text)
values
  (1, 'carta-001', '¿A quién votarías como presidente?'),
  (2, 'carta-002', '¿Con quién no estaría a salvo un secreto?'),
  (3, 'carta-003', '¿Quién criticaría a alguien por algo que también hace?'),
  (4, 'carta-004', '¿Quién tiene más que ocultar en su teléfono?'),
  (5, 'carta-005', '¿Quién se quejaría de un plan antes de empezarlo?'),
  (6, 'carta-006', '¿Quién fingiría más en sus redes sociales?'),
  (7, 'carta-007', '¿Quién llegaría tarde a su propia boda?'),
  (8, 'carta-008', '¿A quién le costaría más admitir un error?'),
  (9, 'carta-009', '¿Quién parece inocente... pero no lo es?'),
  (10, 'carta-010', '¿Quién diría algo raro en una primera cita?'),
  (11, 'carta-011', '¿Quién sería incapaz de disimular cuando algo no le gusta?'),
  (12, 'carta-012', '¿Quién sobreviviría mejor en una isla desierta?'),
  (13, 'carta-013', '¿Quién hablaría mal de ti a tus espaldas?'),
  (14, 'carta-014', '¿Quién llevaría peor quedarse fuera de un plan?'),
  (15, 'carta-015', '¿Quién dirige el grupo sin que nadie se dé cuenta?'),
  (16, 'carta-016', '¿Quién tendría una segunda vida que nadie del grupo conoce?'),
  (17, 'carta-017', '¿Quién sería incapaz de guardar un minuto de silencio?'),
  (18, 'carta-018', '¿Quién enviaría una foto al grupo equivocado?'),
  (19, 'carta-019', '¿Quién se reiría de un chiste sin haberlo entendido?'),
  (20, 'carta-020', '¿Quién desaparece cuando toca pagar?'),
  (21, 'carta-021', '¿Quién tiene siempre una anécdota mejor que los demás?'),
  (22, 'carta-022', '¿Quién se enteraría primero de un chisme?'),
  (23, 'carta-023', '¿Quién te dejaría tirado si le sale un plan mejor?'),
  (24, 'carta-024', '¿Quién inflaría el chaleco salvavidas dentro del avión?'),
  (25, 'carta-025', '¿Quién cometería un error y le echaría la culpa a otro?'),
  (26, 'carta-026', '¿Quién compraría un vuelo antes de saber si puede ir?'),
  (27, 'carta-027', '¿Quién llegaría 3 horas antes al aeropuerto?'),
  (28, 'carta-028', '¿Quién dormiría con la luz encendida después de ver una película de terror?'),
  (29, 'carta-029', '¿Quién desaparecería del mapa si ganara la lotería?'),
  (30, 'carta-030', '¿Quién no podría pasar por delante de un espejo sin mirarse?'),
  (31, 'carta-031', '¿Quién tardaría más en prepararse antes de salir?'),
  (32, 'carta-032', '¿Quién se perdería en su propio barrio?'),
  (33, 'carta-033', '¿Quién ayudaría a un animal antes que a una persona?'),
  (34, 'carta-034', '¿Quién daría más miedo si fuera tu enemigo?'),
  (35, 'carta-035', '¿A quién se le moriría hasta un cactus?'),
  (36, 'carta-036', '¿Quién compraría algo que no necesita porque “estaba de oferta”?'),
  (37, 'carta-037', '¿Quién tardaría más en responder un mensaje?'),
  (38, 'carta-038', '¿Quién tendría la playlist más rara del grupo?'),
  (39, 'carta-039', '¿Quién se reiría en el peor momento posible?'),
  (40, 'carta-040', '¿Quién se creería una teoría de la conspiración?'),
  (41, 'carta-041', '¿Quién juzgaría a alguien por cómo va vestido?'),
  (42, 'carta-042', '¿Quién se llevaría comida de una fiesta para el día siguiente?'),
  (43, 'carta-043', '¿Quién se quedaría escuchando detrás de una puerta?'),
  (44, 'carta-044', '¿Quién entraría en pánico si se para el ascensor?'),
  (45, 'carta-045', '¿Quién haría algo solo porque está prohibido?');

do $$
declare
  v_extra integer;
begin
  select count(*) into v_extra
  from public.cards as card
  where card.active = true
    and card.slug ~ '^carta-[0-9]{3}$'
    and not exists (
      select 1 from pg_temp.desired_voto_cards as desired where desired.slug = card.slug
    );

  if v_extra <> 0 then
    raise exception 'Found % additional active numbered cards. No changes applied.', v_extra;
  end if;
end;
$$;

create table public.cards_voto_backup_20260909 as
select
  desired.position,
  desired.slug,
  card.id as original_id,
  card.question_text as original_question_text,
  card.active as original_active
from pg_temp.desired_voto_cards as desired
left join public.cards as card on card.slug = desired.slug;

alter table public.cards_voto_backup_20260909
  add primary key (slug);

-- Existing rows keep their UUIDs. Only missing slugs receive new rows/UUIDs.
insert into public.cards (slug, question_text, active)
select desired.slug, desired.question_text, true
from pg_temp.desired_voto_cards as desired
where not exists (
  select 1
  from public.cards as card
  where card.slug = desired.slug
);

update public.cards as card
set question_text = desired.question_text,
    active = true
from pg_temp.desired_voto_cards as desired
where card.slug = desired.slug;

do $$
declare
  v_active_count integer;
  v_mismatch_count integer;
begin
  select count(*) into v_active_count
  from public.cards as card
  join pg_temp.desired_voto_cards as desired on desired.slug = card.slug
  where card.active = true;

  select count(*) into v_mismatch_count
  from pg_temp.desired_voto_cards as desired
  join public.cards as card on card.slug = desired.slug
  where card.question_text is distinct from desired.question_text;

  if v_active_count <> 45 or v_mismatch_count <> 0 then
    raise exception 'VOTO card verification failed. No changes applied.';
  end if;
end;
$$;

commit;

-- Final read-only report: the SQL editor should return exactly V-001..V-045.
select
  'V-' || substring(card.slug from '([0-9]{3})$') as visible_code,
  card.id,
  card.slug,
  card.question_text,
  card.active
from public.cards as card
where card.slug between 'carta-001' and 'carta-045'
order by card.slug;
