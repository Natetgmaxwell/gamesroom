-- 099: swap the 098 replacement question (Nathan, 2026-10-05: did not like it either).
-- Removes: What's a smell you secretly love that everyone else hates?
-- Adds:    Which fictional villain was actually right?  (unhinged; keeps 40 = 20 deep / 20 unhinged)
begin;

create or replace function public.question_box_house_deck()
returns table (text text, tag text)
language sql
immutable
set search_path = ''
as $$
  select d.text, d.tag from (values
    (1, 'Which decade would you live in if you had to, and what would you miss most about now?', 'deep'),
    (2, 'If you were a Transformer, what vehicle would you turn into?', 'unhinged'),
    (3, 'Is it kinder to tell a mate the hard truth or let them find out?', 'deep'),
    (4, 'Which person at this table would last longest in a zombie apocalypse, and who goes first?', 'unhinged'),
    (5, 'What''s one job everyone thinks is respectable that you think is mostly a scam?', 'deep'),
    (6, 'What''s the most ridiculous thing you''d do for a million dollars, as long as nobody filmed it?', 'unhinged'),
    (7, 'Would you rather know the date you die or the way you die?', 'deep'),
    (8, 'Rank everyone at the table by who''d be the worst to share a caravan with for a month?', 'unhinged'),
    (9, 'What''s one belief you held at 18 that you''re embarrassed by now?', 'deep'),
    (10, 'Which character from a kids'' show is secretly the most unhinged?', 'unhinged'),
    (11, 'Does keeping score in a relationship ever work?', 'deep'),
    (12, 'If your life had a theme song that played whenever you walked in, what is it?', 'unhinged'),
    (13, 'Which of your opinions would lose you a friend if you said it at a dinner party?', 'deep'),
    (14, 'What''s a completely normal thing that you find deeply suspicious?', 'unhinged'),
    (15, 'Is being funny or being good-looking worth more in the long run?', 'deep'),
    (16, 'Which fictional villain was actually right?', 'unhinged'),
    (17, 'If you could abolish one law tomorrow, which one goes?', 'deep'),
    (18, 'What''s the most unhinged thing you''ve ever done to avoid a phone call?', 'unhinged'),
    (19, 'Should you stay friends with someone whose politics you can''t stand?', 'deep'),
    (20, 'Which sitcom would your friend group fit into, and who plays who?', 'unhinged'),
    (21, 'What''s something everyone pretends to enjoy but secretly doesn''t?', 'deep'),
    (22, 'What''s the most useless superpower you''d secretly love to have?', 'unhinged'),
    (23, 'Who''s a person you admire that most people have never heard of?', 'deep'),
    (24, 'If you could ban one word from the English language forever, what goes?', 'unhinged'),
    (25, 'What''s the best piece of advice you ignored and later wish you hadn''t?', 'deep'),
    (26, 'What''s the weirdest thing you believed as a kid for far too long?', 'unhinged'),
    (27, 'What''s one thing every 16-year-old should be taught that school skips?', 'deep'),
    (28, 'Which table member would be the best at running a dodgy cult?', 'unhinged'),
    (29, 'Would you take a pill that made you happy forever if it meant you''d never achieve anything again?', 'deep'),
    (30, 'What would your last meal be if it also had to be your most embarrassing order?', 'unhinged'),
    (31, 'Is it better to be respected or liked?', 'deep'),
    (32, 'If animals could talk, which one would turn out to be the biggest jerk?', 'unhinged'),
    (33, 'What''s the most overrated milestone in life?', 'deep'),
    (34, 'What''s a perfectly good food you refuse to eat and can''t defend?', 'unhinged'),
    (35, 'Which job would you do for free, and which would you never take for any pay?', 'deep'),
    (36, 'Which celebrity would you pick as your annoying flatmate for a year?', 'unhinged'),
    (37, 'Which person, alive or dead, would you want to argue with for an hour, and about what?', 'deep'),
    (38, 'What''s the dumbest thing you''d name a dog?', 'unhinged'),
    (39, 'Is ambition a virtue, or just insecurity that dresses better?', 'deep'),
    (40, 'What''s the funniest thing you''ve ever gotten in trouble for?', 'unhinged')
  ) as d(ord, text, tag)
  order by d.ord;
$$;

update public.room_questions
   set text = 'Which fictional villain was actually right?'
 where source = 'house'
   and text = 'What''s a smell you secretly love that everyone else hates?';

commit;
