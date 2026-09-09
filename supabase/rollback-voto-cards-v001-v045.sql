-- Restore question text and active flags captured by update-voto-cards-v001-v045.sql.

begin;

do $$
declare
  v_dependent_rounds integer;
begin
  if to_regclass('public.cards_voto_backup_20260909') is null then
    raise exception 'Backup table public.cards_voto_backup_20260909 does not exist.';
  end if;

  if (select count(*) from public.cards_voto_backup_20260909) <> 45 then
    raise exception 'Backup table does not contain the expected 45 cards.';
  end if;

  select count(*) into v_dependent_rounds
  from public.vote_rounds as vote_round
  join public.cards as card on card.id = vote_round.card_id
  join public.cards_voto_backup_20260909 as backup on backup.slug = card.slug
  where backup.original_id is null;

  if v_dependent_rounds <> 0 then
    raise exception 'New cards already have dependent vote rounds; rollback aborted.';
  end if;
end;
$$;

update public.cards as card
set question_text = backup.original_question_text,
    active = backup.original_active
from public.cards_voto_backup_20260909 as backup
where card.id = backup.original_id
  and card.slug = backup.slug;

delete from public.cards as card
using public.cards_voto_backup_20260909 as backup
where card.slug = backup.slug
  and backup.original_id is null;

drop table public.cards_voto_backup_20260909;

commit;
