-- 0006_relax_face_embedding_vector_dimensions.sql
-- Make the face embedding mirror accept both historical 128-d MobileFaceNet
-- vectors and new 512-d AWS AdaFace vectors. This is intentionally idempotent
-- so it can be applied to databases that missed or partially applied 0005.

set statement_timeout = '120s';

drop index if exists face_embeddings_vector_cosine_idx;
drop index if exists face_embeddings_vector512_cosine_idx;
drop index if exists person_avg_face_embeddings_vec_idx;
drop index if exists person_avg_face_embeddings_vec512_idx;

alter table face_embeddings
  alter column vector type vector using vector::vector,
  alter column dimension drop default;

alter table face_embeddings
  alter column dimension set default 512;

alter table person_averaged_face_embeddings
  alter column averaged_vector type vector using averaged_vector::vector,
  alter column vector_dimension drop default;

alter table person_averaged_face_embeddings
  alter column vector_dimension set default 512;

create index if not exists face_embeddings_vector128_cosine_idx
  on face_embeddings using ivfflat ((vector::vector(128)) vector_cosine_ops) with (lists = 100)
  where dimension = 128;

create index if not exists face_embeddings_vector512_cosine_idx
  on face_embeddings using ivfflat ((vector::vector(512)) vector_cosine_ops) with (lists = 100)
  where dimension = 512;

create index if not exists person_avg_face_embeddings_vec128_idx
  on person_averaged_face_embeddings using ivfflat ((averaged_vector::vector(128)) vector_cosine_ops) with (lists = 50)
  where vector_dimension = 128;

create index if not exists person_avg_face_embeddings_vec512_idx
  on person_averaged_face_embeddings using ivfflat ((averaged_vector::vector(512)) vector_cosine_ops) with (lists = 50)
  where vector_dimension = 512;

notify pgrst, 'reload schema';
