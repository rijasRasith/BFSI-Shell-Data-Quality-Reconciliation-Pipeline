USE banking_pipeline;

LOAD DATA LOCAL INFILE '/path/to/data/account_master.csv'
INTO TABLE account_master
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(account_id, account_name, account_type, branch, status);
