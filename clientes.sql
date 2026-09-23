--------------------------------------------------------------------------------
-- Archivo      : clientes.sql
-- Descripción  : Alta de clientes con correo electrónico único. Crea la tabla
--                CLIENTES, su secuencia de identificadores y el procedimiento
--                de inserción SP_INSERTAR_CLIENTE, con validaciones de entrada
--                y gestión completa de excepciones.
-- Base de datos: Oracle Database 11g o superior
-- Autor        : madag7
-- Fecha creación : 22/09/2026
-- Última modif.  : 23/09/2026
--------------------------------------------------------------------------------
-- OBJETOS QUE CREA ESTE SCRIPT
--------------------------------------------------------------------------------
--  1) TABLA  clientes
--     Registro maestro de clientes.
--       id_cliente  NUMBER(10)    PK, se asigna desde seq_clientes
--       nombre      VARCHAR2(100) Obligatorio
--       apellido    VARCHAR2(100) Opcional
--       correo      VARCHAR2(150) Obligatorio, único sin distinguir mayúsculas
--       telefono    VARCHAR2(20)  Opcional
--       direccion   VARCHAR2(100) Opcional
--       fecha_alta  DATE          Obligatorio, por defecto SYSDATE
--       activo      CHAR(1)       Obligatorio, 'S' o 'N', por defecto 'S'
--
--  2) ÍNDICE  uk_clientes_correo  (ÚNICO, basado en función)
--     Impone la unicidad del correo sobre LOWER(TRIM(correo)), de modo que
--     'Ana@X.com' y 'ana@x.com' se consideran el mismo correo. Se usa un
--     índice y no una constraint UNIQUE porque Oracle no admite expresiones
--     dentro de una constraint.
--
--  3) CONSTRAINT  ck_clientes_correo
--     Valida por expresión regular el formato mínimo texto@texto.dominio.
--
--  4) CONSTRAINT  ck_clientes_activo
--     Restringe la columna activo a los valores 'S' o 'N'.
--
--  5) SECUENCIA  seq_clientes
--     Genera los id_cliente. START WITH 1, INCREMENT BY 1, NOCACHE NOCYCLE.
--     NOCACHE evita huecos en la numeración a costa de algo de rendimiento.
--
--  6) PROCEDIMIENTO  sp_insertar_cliente
--     Da de alta un cliente validando los datos antes de insertar. No hace
--     COMMIT: el control de la transacción queda en manos del llamante.
--
--     PARÁMETROS DE ENTRADA
--       p_nombre     IN  clientes.nombre%TYPE
--                        Nombre del cliente. Obligatorio; se guarda con TRIM.
--       p_apellido   IN  clientes.apellido%TYPE   DEFAULT NULL
--                        Apellido. Opcional; se guarda con TRIM.
--       p_correo     IN  clientes.correo%TYPE
--                        Correo. Obligatorio; se normaliza a LOWER(TRIM(...))
--                        antes de validar y de insertar.
--       p_telefono   IN  clientes.telefono%TYPE   DEFAULT NULL
--                        Teléfono. Opcional; se guarda con TRIM.
--       p_direccion  IN  clientes.direccion%TYPE  DEFAULT NULL
--                        Dirección postal. Opcional; se guarda con TRIM.
--
--     PARÁMETRO DE SALIDA
--       p_id_cliente OUT clientes.id_cliente%TYPE
--                        Identificador asignado al nuevo cliente. Se devuelve
--                        NULL si la operación falla.
--
--     ERRORES QUE DEVUELVE  (detalle en la cabecera del apartado 3)
--       -20001..-20003  Validaciones de entrada (nombre, correo, formato)
--       -20004..-20005  Violaciones de unicidad
--       -20006..-20009  Violaciones de restricciones y errores de conversión
--       -20099          Error inesperado, con SQLCODE, SQLERRM y traza
--
--  7) BLOQUES ANÓNIMOS DE PRUEBA (apartado 4)
--     Cuatro casos de ejemplo: alta correcta, correo duplicado en mayúsculas,
--     formato de correo inválido y nombre más largo que la columna.
--
--------------------------------------------------------------------------------
-- USO
--   Ejecutar el script completo sobre un esquema vacío:
--     SQL> @clientes.sql
--   Requiere SET SERVEROUTPUT ON para ver la salida de los bloques de prueba
--   (el script ya lo activa).
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
    direccion         VARCHAR2(100),
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
--
--    Códigos de error devueltos a la aplicación:
--      -20001  El nombre es obligatorio
--      -20002  El correo es obligatorio
--      -20003  Formato de correo inválido
--      -20004  Correo ya registrado (duplicado)
--      -20005  Otra violación de unicidad (p. ej. clave primaria)
--      -20006  Campo obligatorio nulo         (ORA-01400)
--      -20007  Restricción CHECK violada      (ORA-02290)
--      -20008  Valor demasiado largo          (ORA-12899)
--      -20009  Error de conversión de datos   (VALUE_ERROR / INVALID_NUMBER)
--      -20099  Error inesperado de base de datos (incluye traza interna)
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_insertar_cliente (
    p_nombre      IN  clientes.nombre%TYPE,
    p_apellido    IN  clientes.apellido%TYPE DEFAULT NULL,
    p_correo      IN  clientes.correo%TYPE,
    p_telefono    IN  clientes.telefono%TYPE DEFAULT NULL,
    p_direccion   IN  clientes.direccion%TYPE DEFAULT NULL,
    p_id_cliente  OUT clientes.id_cliente%TYPE
)
IS
    -- Errores de restricción que el INSERT puede lanzar.
    -- ORA-00001 no se declara: Oracle ya lo expone como DUP_VAL_ON_INDEX.
    e_valor_nulo      EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_valor_nulo,    -1400);   -- NOT NULL violado
    e_check_violado   EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_check_violado, -2290);   -- CHECK violado
    e_valor_largo     EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_valor_largo,   -12899);  -- value too large for column

    -- Rango reservado por Oracle para errores de aplicación
    c_err_app_min CONSTANT PLS_INTEGER := -20999;
    c_err_app_max CONSTANT PLS_INTEGER := -20000;

    v_correo   clientes.correo%TYPE;
    v_existe   PLS_INTEGER;
BEGIN
    -- Punto de retorno: si algo falla, se deshace solo lo hecho por este
    -- procedimiento, sin tocar la transacción abierta por el llamante.
    SAVEPOINT sp_antes_alta;

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

    INSERT INTO clientes (id_cliente, nombre, apellido, correo, telefono,
                          direccion)
    VALUES (seq_clientes.NEXTVAL, TRIM(p_nombre), TRIM(p_apellido),
            v_correo, TRIM(p_telefono), TRIM(p_direccion))
    RETURNING id_cliente INTO p_id_cliente;

EXCEPTION
    -- Red de seguridad ante concurrencia: si dos sesiones pasan a la vez la
    -- validación previa, el índice único sigue protegiendo la integridad.
    WHEN DUP_VAL_ON_INDEX THEN
        ROLLBACK TO sp_antes_alta;
        p_id_cliente := NULL;
        -- ORA-00001 puede venir del correo o de la clave primaria; hay que
        -- distinguirlos para no dar un mensaje engañoso.
        IF INSTR(UPPER(SQLERRM), 'UK_CLIENTES_CORREO') > 0 THEN
            RAISE_APPLICATION_ERROR(-20004,
                'Ya existe un cliente registrado con el correo: ' || v_correo);
        ELSE
            RAISE_APPLICATION_ERROR(-20005,
                'Violación de unicidad al insertar el cliente: ' || SQLERRM);
        END IF;

    WHEN e_valor_nulo THEN
        ROLLBACK TO sp_antes_alta;
        p_id_cliente := NULL;
        RAISE_APPLICATION_ERROR(-20006,
            'Falta un campo obligatorio: ' || SQLERRM);

    WHEN e_check_violado THEN
        ROLLBACK TO sp_antes_alta;
        p_id_cliente := NULL;
        RAISE_APPLICATION_ERROR(-20007,
            'Los datos no cumplen una restricción de la tabla: ' || SQLERRM);

    WHEN e_valor_largo THEN
        ROLLBACK TO sp_antes_alta;
        p_id_cliente := NULL;
        RAISE_APPLICATION_ERROR(-20008,
            'Algún valor excede la longitud permitida: ' || SQLERRM);

    WHEN VALUE_ERROR OR INVALID_NUMBER THEN
        ROLLBACK TO sp_antes_alta;
        p_id_cliente := NULL;
        RAISE_APPLICATION_ERROR(-20009,
            'Error de conversión o tamaño en los datos de entrada: ' || SQLERRM);

    -- Cualquier otro error de base de datos.
    WHEN OTHERS THEN
        ROLLBACK TO sp_antes_alta;
        p_id_cliente := NULL;
        -- Los errores de negocio (-20000..-20999) ya llevan un mensaje claro:
        -- se relanzan tal cual en lugar de envolverlos otra vez.
        IF SQLCODE BETWEEN c_err_app_min AND c_err_app_max THEN
            RAISE;
        END IF;
        -- El mensaje de RAISE_APPLICATION_ERROR admite 2048 bytes como máximo,
        -- y la traza puede ser larga: se recorta para no perder el error real.
        RAISE_APPLICATION_ERROR(-20099,
            SUBSTR('Error inesperado al dar de alta el cliente (ORA'
                   || SQLCODE || '): ' || SQLERRM || CHR(10)
                   || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 2000),
            TRUE);
END sp_insertar_cliente;
/

-- Comprobación de compilación: muestra los errores si el procedimiento quedó
-- INVALID en lugar de fallar en silencio.
SHOW ERRORS PROCEDURE sp_insertar_cliente

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
        p_direccion  => 'Calle Mayor 1, 28013 Madrid',
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

-- Correo con formato inválido -> debe fallar con ORA-20003
DECLARE
    v_id clientes.id_cliente%TYPE;
BEGIN
    sp_insertar_cliente(
        p_nombre     => 'Luis',
        p_correo     => 'luis.sin.arroba',
        p_id_cliente => v_id
    );
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error esperado: ' || SQLERRM);
END;
/

-- Nombre más largo que la columna -> lo captura el bloque de longitud/conversión
-- (ORA-20008 si salta en el INSERT, ORA-20009 si salta antes, al convertir).
DECLARE
    v_id     clientes.id_cliente%TYPE;
    v_nombre VARCHAR2(200) := RPAD('X', 150, 'X');
BEGIN
    sp_insertar_cliente(
        p_nombre     => v_nombre,
        p_correo     => 'nombre.largo@ejemplo.com',
        p_id_cliente => v_id
    );
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error esperado: ' || SQLERRM);
END;
/
