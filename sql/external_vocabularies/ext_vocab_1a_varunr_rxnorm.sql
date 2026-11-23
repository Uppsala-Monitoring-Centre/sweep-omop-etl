-- create destination schema for externally sourced NPLID mapping file
DROP TABLE IF EXISTS {{EXT_VOCAB_SCHEMA}}.nplid_rxnorm;

CREATE TABLE {{EXT_VOCAB_SCHEMA}}.nplid_rxnorm(
	src_val TEXT,
	src_desc_raw_product_name TEXT,
	atc TEXT,
	src_desc_formtext_sv TEXT,
	src_desc_strengthtext_original TEXT,
	src_desc_strengthtext_generated TEXT,
	src_desc_substancename_sv TEXT,
	src_count TEXT,
	dst_val TEXT,
	dst_desc TEXT,
	dst_domain TEXT,
	dst_class TEXT,
	dst_vocab TEXT,
	src_desc_substancename_en TEXT,
	src_desc_formtext_en TEXT
);