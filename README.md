# Oracle SQL & PL/SQL Practices

Prácticas de Oracle Database centradas en el diseño de objetos de base de datos y en la escritura de procedimientos PL/SQL robustos, con validación de entrada y gestión exhaustiva de excepciones.

## Descripción ejecutiva

Este repositorio contiene un caso práctico completo de **alta de clientes con correo electrónico único**. El script [`clientes.sql`](clientes.sql) es autocontenido: crea la tabla, sus restricciones, la secuencia de identificadores y el procedimiento almacenado de inserción, e incluye bloques anónimos de prueba que demuestran tanto el camino correcto como los principales escenarios de error.

El objetivo no es solo insertar filas, sino mostrar cómo se construye un procedimiento apto para producción:

- La integridad se garantiza **en la base de datos** (restricciones e índices), no solo en el código.
- El procedimiento traduce los errores internos de Oracle a **códigos de aplicación estables** (`ORA-20001` … `ORA-20099`), con mensajes legibles para la capa llamante.
- El control de la transacción se delega al llamante: el procedimiento **no hace `COMMIT`**, y usa un `SAVEPOINT` para deshacer únicamente su propio trabajo en caso de fallo.

## Contenido del repositorio

| Archivo | Descripción |
| --- | --- |
| `clientes.sql` | Script completo: DDL, secuencia, procedimiento `SP_INSERTAR_CLIENTE` y pruebas. |
| `.gitignore` | Exclusiones de artefactos locales y de herramientas. |

## Características técnicas

### Modelo de datos

**Tabla `CLIENTES`**

| Columna | Tipo | Notas |
| --- | --- | --- |
| `id_cliente` | `NUMBER(10)` | Clave primaria (`pk_clientes`), asignada desde `seq_clientes`. |
| `nombre` | `VARCHAR2(100)` | Obligatorio. |
| `apellido` | `VARCHAR2(100)` | Opcional. |
| `correo` | `VARCHAR2(150)` | Obligatorio y único sin distinguir mayúsculas. |
| `telefono` | `VARCHAR2(20)` | Opcional. |
| `fecha_alta` | `DATE` | Obligatorio, por defecto `SYSDATE`. |
| `activo` | `CHAR(1)` | Obligatorio, `'S'` o `'N'`, por defecto `'S'`. |

**Objetos asociados**

- `uk_clientes_correo` — índice **único basado en función** sobre `LOWER(TRIM(correo))`. Se emplea un índice en lugar de una constraint `UNIQUE` porque Oracle no admite expresiones dentro de una constraint; gracias a él, `Ana@X.com` y `ana@x.com` se consideran el mismo correo.
- `ck_clientes_correo` — constraint `CHECK` que valida por expresión regular el formato mínimo `texto@texto.dominio`.
- `ck_clientes_activo` — constraint `CHECK` que restringe `activo` a `'S'` o `'N'`.
- `seq_clientes` — secuencia `START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE`. `NOCACHE` evita huecos en la numeración a costa de algo de rendimiento.

### Procedimiento `SP_INSERTAR_CLIENTE`

```sql
PROCEDURE sp_insertar_cliente (
    p_nombre      IN  clientes.nombre%TYPE,
    p_apellido    IN  clientes.apellido%TYPE DEFAULT NULL,
    p_correo      IN  clientes.correo%TYPE,
    p_telefono    IN  clientes.telefono%TYPE DEFAULT NULL,
    p_id_cliente  OUT clientes.id_cliente%TYPE
);
```

Devuelve en `p_id_cliente` el identificador asignado, o `NULL` si la operación falla.

**Validaciones previas a la inserción**

1. **Normalización de entrada** — el correo se convierte a `LOWER(TRIM(...))` antes de validarse y de insertarse; nombre, apellido y teléfono se almacenan con `TRIM`.
2. **Nombre obligatorio** — se rechaza tanto `NULL` como una cadena compuesta solo de espacios.
3. **Correo obligatorio** — comprobado tras la normalización.
4. **Formato de correo** — validado con `REGEXP_LIKE` antes de tocar la tabla.
5. **Duplicado explícito** — se consulta la existencia previa del correo para devolver un mensaje claro en lugar de dejar que salte el error genérico del índice.

**Gestión de excepciones**

El bloque `EXCEPTION` cubre los errores concretos que puede lanzar el `INSERT`, declarados mediante `PRAGMA EXCEPTION_INIT`, y termina con una cláusula `WHEN OTHERS` como red de seguridad. En todos los casos se hace `ROLLBACK TO sp_antes_alta`, se anula el identificador de salida y se relanza el fallo con un código de aplicación:

| Código | Situación |
| --- | --- |
| `ORA-20001` | El nombre es obligatorio. |
| `ORA-20002` | El correo es obligatorio. |
| `ORA-20003` | Formato de correo inválido. |
| `ORA-20004` | Correo ya registrado (validación previa o `DUP_VAL_ON_INDEX` sobre `uk_clientes_correo`). |
| `ORA-20005` | Otra violación de unicidad, por ejemplo en la clave primaria. |
| `ORA-20006` | Campo obligatorio nulo (`ORA-01400`). |
| `ORA-20007` | Restricción `CHECK` violada (`ORA-02290`). |
| `ORA-20008` | Valor demasiado largo para la columna (`ORA-12899`). |
| `ORA-20009` | Error de conversión de datos (`VALUE_ERROR` / `INVALID_NUMBER`). |
| `ORA-20099` | Error inesperado, con `SQLCODE`, `SQLERRM` y traza interna. |

Detalles de implementación destacables:

- **Seguridad ante concurrencia** — la comprobación previa de duplicados es una mejora de usabilidad, no la garantía de integridad: si dos sesiones la superan a la vez, el índice único sigue protegiendo los datos y `DUP_VAL_ON_INDEX` lo captura.
- **Diagnóstico preciso** — `ORA-00001` puede proceder del correo o de la clave primaria, así que se inspecciona `SQLERRM` para distinguir ambos casos y no emitir un mensaje engañoso.
- **Errores de negocio sin envolver** — en `WHEN OTHERS`, los códigos del rango reservado `-20999..-20000` se relanzan con `RAISE` tal cual, evitando enmascararlos dos veces.
- **Traza acotada** — `DBMS_UTILITY.FORMAT_ERROR_BACKTRACE` se adjunta al error inesperado recortada a 2000 caracteres, ya que el mensaje de `RAISE_APPLICATION_ERROR` admite como máximo 2048 bytes.

### Bloques de prueba incluidos

El script cierra con cuatro bloques anónimos que ejercitan el procedimiento:

1. Alta correcta de un cliente.
2. Reinserción del mismo correo en mayúsculas → `ORA-20004`.
3. Correo sin formato válido → `ORA-20003`.
4. Nombre más largo que la columna → `ORA-20008` u `ORA-20009`.

## Requisitos previos

- **Oracle Database 11g o superior** (probado con la sintaxis compatible desde 11g). Sirve cualquier edición, incluida Oracle Database XE.
- Un cliente SQL: **Oracle SQL Developer**, **SQL\*Plus** o **SQLcl**.
- Un **esquema de usuario vacío** con privilegios `CREATE TABLE`, `CREATE SEQUENCE`, `CREATE PROCEDURE` y cuota sobre su tablespace.
- `SET SERVEROUTPUT ON` para ver la salida de los bloques de prueba (el propio script lo activa).

## Ejecución

Clona el repositorio y ejecuta el script completo sobre el esquema de destino:

```bash
git clone https://github.com/madag7/oracle-sql-plsql-practices.git
cd oracle-sql-plsql-practices
```

Desde SQL\*Plus o SQLcl:

```sql
SQL> @clientes.sql
```

Desde SQL Developer: abre `clientes.sql` y ejecútalo como script con **F5**.

> El script asume un esquema limpio: si los objetos ya existen, las sentencias `CREATE TABLE` y `CREATE SEQUENCE` fallarán. Para volver a ejecutarlo, elimina antes los objetos:
>
> ```sql
> DROP PROCEDURE sp_insertar_cliente;
> DROP TABLE clientes PURGE;
> DROP SEQUENCE seq_clientes;
> ```

### Ejemplo de uso desde tu propio código

```sql
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
```

Recuerda que el procedimiento no confirma la transacción: el `COMMIT` o el `ROLLBACK` corresponden al llamante.

## Autoría

Desarrollado por **[@madag7](https://github.com/madag7)**.

Repositorio: [github.com/madag7/oracle-sql-plsql-practices](https://github.com/madag7/oracle-sql-plsql-practices)
