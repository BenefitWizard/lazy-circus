{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE MultilineStrings #-}
{-# LANGUAGE StandaloneDeriving #-}

module Common where

import Database.Beam
import Database.Beam.Postgres (Postgres)
import Database.PostgreSQL.Simple.FromRow (FromRow)
import LazyCircus.DB.Service
import LazyCircus.DB.Types (PgDB)
import LazyCircus.Scene.DB.RLS (RLSContext (..))
import RIO
import RIO.Time (UTCTime)

-- | Beam table for circus acts and its concrete aliases.
data CircusActT f = CircusAct
    { circusActId :: Columnar f Int32
    , circusActName :: Columnar f Text
    , circusId :: Columnar f Int32
    , circusActDescription :: Columnar f Text
    , circusActAudienceReaction :: Columnar f (Maybe Text)
    }
    deriving (Generic, Beamable)

type CircusAct = CircusActT Identity

deriving instance Show CircusAct
deriving instance Eq CircusAct
-- | Allows decoding CircusAct rows from raw SQL queries via postgresql-simple.
deriving anyclass instance FromRow CircusAct

type CircusActId = PrimaryKey CircusActT Identity

deriving instance Show CircusActId
deriving instance Eq CircusActId

instance Table CircusActT where
    data PrimaryKey CircusActT f
        = CircusActId (Columnar f Int32)
        deriving (Generic, Beamable)
    primaryKey = CircusActId <$> circusActId

-- | Beam table for Telegram Stars payments and its concrete aliases.
data StarsPaymentT f = StarsPayment
    { starsPaymentId :: Columnar f Int32
    , starsPaymentTelegramPaymentChargeId :: Columnar f Text
    , starsPaymentUserId :: Columnar f (Maybe Int64)
    , starsPaymentStars :: Columnar f (Maybe Int32)
    , starsPaymentCurrencyAmount :: Columnar f (Maybe Int64)
    , starsPaymentInvoicePayload :: Columnar f (Maybe Text)
    , starsPaymentCreatedAt :: Columnar f (Maybe UTCTime)
    }
    deriving (Generic, Beamable)

type StarsPayment = StarsPaymentT Identity

deriving instance Show StarsPayment
deriving instance Eq StarsPayment
-- | Allows decoding StarsPayment rows from raw SQL queries via postgresql-simple.
deriving anyclass instance FromRow StarsPayment

type StarsPaymentId = PrimaryKey StarsPaymentT Identity

deriving instance Show StarsPaymentId
deriving instance Eq StarsPaymentId

instance Table StarsPaymentT where
    data PrimaryKey StarsPaymentT f
        = StarsPaymentId (Columnar f Int32)
        deriving (Generic, Beamable)
    primaryKey = StarsPaymentId <$> starsPaymentId

data SimpleDb f = SimpleDb
    { _circusActs :: f (TableEntity CircusActT)
    , _starsPayments :: f (TableEntity StarsPaymentT)
    }
    deriving (Generic)

instance Database Postgres SimpleDb

-- | Explicit Beam settings that pin the SQL table and column names used by 'migration'.
simpleDb :: PgDB SimpleDb
simpleDb =
    defaultDbSettings `withDbModification` dbMod
        { _circusActs =
            mempty
                <> setEntityName "circus_acts"
                <> modifyTableFields
                    tableModification
                    { circusActId = fieldNamed "id"
                    , circusActName = fieldNamed "name"
                    , circusId = fieldNamed "circus_id"
                    , circusActDescription = fieldNamed "description"
                    , circusActAudienceReaction = fieldNamed "audience_reaction"
                    }
        , _starsPayments =
            mempty
                <> setEntityName "stars_payments"
                <> modifyTableFields
                    tableModification
                        { starsPaymentId = fieldNamed "id"
                        , starsPaymentTelegramPaymentChargeId = fieldNamed "telegram_payment_charge_id"
                        , starsPaymentUserId = fieldNamed "user_id"
                        , starsPaymentStars = fieldNamed "stars"
                        , starsPaymentCurrencyAmount = fieldNamed "currency_amount"
                        , starsPaymentInvoicePayload = fieldNamed "invoice_payload"
                        , starsPaymentCreatedAt = fieldNamed "created_at"
                        }
        }
  where
    dbMod :: DatabaseModification (DatabaseEntity Postgres SimpleDb) Postgres SimpleDb
    dbMod = dbModification

-- LAW: getTargetTable returns the circusActs entity from the schema.
instance IsInDb SimpleDb CircusActT where
    getTargetTable = _circusActs

instance HasCreateService SimpleDb CircusActT where
    generateInsert db rows =
        insert (_circusActs db) $
            insertExpressions $
                map
                    ( \r ->
                        CircusAct
                            { circusActId = maybe default_ val_ (circusActId r)
                            , circusId = maybe default_ val_ (circusId r)
                            , circusActName = maybe (val_ "") val_ (circusActName r)
                            , circusActDescription = maybe (val_ "") val_ (circusActDescription r)
                            , circusActAudienceReaction = maybe nothing_ (maybe nothing_ (just_ . val_)) (circusActAudienceReaction r)
                            }
                    )
                    rows

instance HasReadService SimpleDb CircusActT where
    type LId CircusActT = CircusActId
    generateSelect db (CircusActId i) =
        lookup_ (_circusActs db) (CircusActId i)
    generateFiltration _db (CircusActId i) t =
        circusActId t ==. val_ i

instance HasUpdateService SimpleDb CircusActT where
    generateAssigment _db partial t =
        mconcat
            [ maybe mempty (\v -> circusActName t <-. val_ v) (circusActName partial)
            , maybe mempty (\v -> circusActDescription t <-. val_ v) (circusActDescription partial)
            , maybe mempty (\v -> circusActAudienceReaction t <-. val_ v) (circusActAudienceReaction partial)
            ]

instance HasDeleteService SimpleDb CircusActT

-- | RLS context keyed by the circus domain tenant column @circus_id@,
-- matching the @circus_acts_circus_rls@ policy in 'migration'.
rlsCircusId :: Int32 -> RLSContext
rlsCircusId circusId = RLSContext [("circus_id", tshow circusId)]

migration :: Text
migration =
    """
    CREATE TABLE circus_acts (
        id SERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        circus_id INT NOT NULL,
        description TEXT NOT NULL,
        audience_reaction TEXT
    );

    DO $$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lazy_circus_app') THEN
            CREATE ROLE lazy_circus_app LOGIN PASSWORD 'my_password';
        END IF;
    END
    $$;

    ALTER ROLE lazy_circus_app WITH PASSWORD 'my_password';
    GRANT USAGE ON SCHEMA public TO lazy_circus_app;
    GRANT SELECT, INSERT, UPDATE, DELETE ON circus_acts TO lazy_circus_app;
    GRANT USAGE, SELECT ON SEQUENCE circus_acts_id_seq TO lazy_circus_app;

    ALTER TABLE circus_acts ENABLE ROW LEVEL SECURITY;

    CREATE POLICY circus_acts_circus_rls
        ON circus_acts
        FOR ALL
        USING (
            CASE
                WHEN NULLIF(current_setting('rls.circus_id', true), '') IS NULL THEN TRUE
                ELSE circus_id = NULLIF(current_setting('rls.circus_id', true), '')::INT
            END
        )
        WITH CHECK (
            CASE
                WHEN NULLIF(current_setting('rls.circus_id', true), '') IS NULL THEN TRUE
                ELSE circus_id = NULLIF(current_setting('rls.circus_id', true), '')::INT
            END
        );

    -- Demo-wide wallet table: intentionally not tenant-scoped (no RLS).
    CREATE TABLE stars_payments (
        id SERIAL PRIMARY KEY,
        telegram_payment_charge_id TEXT NOT NULL UNIQUE,
        user_id BIGINT,
        stars INTEGER,
        currency_amount BIGINT,
        invoice_payload TEXT,
        created_at TIMESTAMPTZ
    );

    GRANT SELECT, INSERT, UPDATE, DELETE ON stars_payments TO lazy_circus_app;
    GRANT USAGE, SELECT ON SEQUENCE stars_payments_id_seq TO lazy_circus_app;
    """
