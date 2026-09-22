--------------------------------------------------------------------------------
-- clientes.sql
-- Tabla CLIENTES + procedimiento PL/SQL de alta con validación de correo único.
-- Probado sobre Oracle Database 11g o superior.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON

--------------------------------------------------------------------------------
-- 1. Tabla
--------------------------------------------------------------------------------
CREATE TABLE clientes (
    id_cliente        NUMBER(10)      NOT NULL,
    nombre            VARCHAR2(100)   NOT NULL,
    apellido          VARCHAR2(100),
    correo            VARCHAR2(150)   NOT NULL,
    telefono          VARCHAR2(20),
    fecha_alta        DATE            DEFAULT SYSDATE NOT NULL,
    activo            CHAR(1)         DEFAULT 'S'     NOT NULL,
    CONSTRAINT pk_clientes            PRIMARY KEY (id_cliente)
);

-- Oracle no admite expresiones en una constraint UNIQUE, así que la unicidad
-- "case-insensitive" del correo se impone con un índice único basado en función.
CREATE UNIQUE INDEX uk_clientes_correo
    ON clientes (LOWER(TRIM(correo)));

-- Formato mínimo de correo (texto@texto.dominio)
ALTER TABLE clientes ADD CONSTRAINT ck_clientes_correo
    CHECK (REGEXP_LIKE(correo, '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'));

ALTER TABLE clientes ADD CONSTRAINT ck_clientes_activo
    CHECK (activo IN ('S', 'N'));

--------------------------------------------------------------------------------
-- 2. Secuencia para el identificador
--------------------------------------------------------------------------------
CREATE SEQUENCE seq_clientes
    START WITH 1
    INCREMENT BY 1
    NOCACHE
    NOCYCLE;

--------------------------------------------------------------------------------
-- 3. Procedimiento de alta
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_insertar_cliente (
    p_nombre      IN  clientes.nombre%TYPE,
    p_apellido    IN  clientes.apellido%TYPE DEFAULT NULL,
    p_correo      IN  clientes.correo%TYPE,
    p_telefono    IN  clientes.telefono%TYPE DEFAULT NULL,
    p_id_cliente  OUT clientes.id_cliente%TYPE
)
IS
    e_correo_duplicado  EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_correo_duplicado, -1);  -- ORA-00001: unique constraint

    v_correo   clientes.correo%TYPE;
    v_existe   PLS_INTEGER;
BEGIN
    -- Normalización de entrada
    v_correo := LOWER(TRIM(p_correo));

    IF p_nombre IS NULL OR TRIM(p_nombre) IS NULL THEN
        RAISE_APPLICATION_ERROR(-20001, 'El nombre es obligatorio.');
    END IF;

    IF v_correo IS NULL THEN
        RAISE_APPLICATION_ERROR(-20002, 'El correo electrónico es obligatorio.');
    END IF;

    IF NOT REGEXP_LIKE(v_correo, '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$') THEN
        RAISE_APPLICATION_ERROR(-20003,
            'El correo electrónico no tiene un formato válido: ' || v_correo);
    END IF;

    -- Validación explícita de duplicado (mensaje claro para la aplicación)
    SELECT COUNT(*)
      INTO v_existe
      FROM clientes
     WHERE LOWER(TRIM(correo)) = v_correo;

    IF v_existe > 0 THEN
        RAISE_APPLICATION_ERROR(-20004,
            'Ya existe un cliente registrado con el correo: ' || v_correo);
    END IF;

    INSERT INTO clientes (id_cliente, nombre, apellido, correo, telefono)
    VALUES (seq_clientes.NEXTVAL, TRIM(p_nombre), TRIM(p_apellido),
            v_correo, TRIM(p_telefono))
    RETURNING id_cliente INTO p_id_cliente;

EXCEPTION
    -- Red de seguridad: si dos sesiones concurrentes pasan la validación previa,
    -- el índice único sigue protegiendo la integridad.
    WHEN e_correo_duplicado THEN
        RAISE_APPLICATION_ERROR(-20004,
            'Ya existe un cliente registrado con el correo: ' || v_correo);
END sp_insertar_cliente;
/

--------------------------------------------------------------------------------
-- 4. Ejemplo de uso
--------------------------------------------------------------------------------
DECLARE
    v_id clientes.id_cliente%TYPE;
BEGIN
    sp_insertar_cliente(
        p_nombre     => 'Ana',
        p_apellido   => 'García',
        p_correo     => 'ana.garcia@ejemplo.com',
        p_telefono   => '600123456',
        p_id_cliente => v_id
    );
    DBMS_OUTPUT.PUT_LINE('Cliente insertado con id = ' || v_id);
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
END;
/

-- Segundo intento con el mismo correo (en mayúsculas) -> debe fallar con ORA-20004
DECLARE
    v_id clientes.id_cliente%TYPE;
BEGIN
    sp_insertar_cliente(
        p_nombre     => 'Ana',
        p_correo     => 'ANA.GARCIA@EJEMPLO.COM',
        p_id_cliente => v_id
    );
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error esperado: ' || SQLERRM);
END;
/
