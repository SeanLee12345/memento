-- Switch face embedding storage from old local 128-dim embeddings to AWS
-- AdaFace 512-dim embeddings. Existing local embeddings remain queryable in
-- Postgres by relaxing the pgvector typmod; new AdaFace rows can now sync.
--
-- The app gates matching by model/version/preprocessing, so mixed historical
-- rows are not compared against AdaFace live embeddings.

drop index if exists face_embeddings_vector_cosine_idx;
drop index if exists person_avg_face_embeddings_vec_idx;

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

create index if not exists face_embeddings_vector512_cosine_idx
  on face_embeddings using ivfflat ((vector::vector(512)) vector_cosine_ops) with (lists = 100)
  where dimension = 512;

create index if not exists person_avg_face_embeddings_vec512_idx
  on person_averaged_face_embeddings using ivfflat ((averaged_vector::vector(512)) vector_cosine_ops) with (lists = 50)
  where vector_dimension = 512;
