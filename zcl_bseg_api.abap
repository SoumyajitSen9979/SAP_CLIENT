CLASS zcl_bseg_api DEFINITION PUBLIC FINAL CREATE PUBLIC.
  PUBLIC SECTION.
    INTERFACES if_http_extension.
  PRIVATE SECTION.
    TYPES ty_strings TYPE STANDARD TABLE OF string WITH DEFAULT KEY.
    CONSTANTS c_max_rows TYPE i VALUE 5000.
    " Whitelist. Add tables here as the AI needs them.
    CONSTANTS c_allowed TYPE string
      VALUE 'BSEG,BKPF,ACDOCA,SKA1,SKAT,SKB1,LFA1,KNA1,T001,CSKS,BSID,BSAD,BSIK,BSAK'.

    DATA mo_server TYPE REF TO if_http_server.
    DATA mv_table  TYPE tabname.
    DATA mt_dfies  TYPE ddfields.
    DATA mv_error  TYPE string.

    METHODS h_tables.
    METHODS h_meta.
    METHODS h_query.
    METHODS h_aggregate.
    METHODS h_document.

    METHODS load_table   IMPORTING iv_table TYPE string RETURNING VALUE(rv_ok) TYPE abap_bool.
    METHODS param        IMPORTING iv_name TYPE string iv_default TYPE string OPTIONAL
                         RETURNING VALUE(rv_val) TYPE string.
    METHODS field_exists IMPORTING iv_name TYPE string RETURNING VALUE(rv_ok) TYPE abap_bool.
    METHODS build_fields IMPORTING iv_fields TYPE string RETURNING VALUE(rt_fields) TYPE ty_strings.
    METHODS build_where  IMPORTING iv_filter TYPE string RETURNING VALUE(rv_where) TYPE string.
    METHODS build_order  IMPORTING iv_order TYPE string it_allowed TYPE ty_strings OPTIONAL
                         RETURNING VALUE(rv_order) TYPE string.
    METHODS sql_value    IMPORTING iv_field TYPE string iv_value TYPE string
                         RETURNING VALUE(rv_sql) TYPE string.
    METHODS field_type   IMPORTING iv_field TYPE string RETURNING VALUE(ro_type) TYPE REF TO cl_abap_datadescr.
    METHODS send         IMPORTING iv_status TYPE i iv_body TYPE string.
    METHODS send_json    IMPORTING ia_data TYPE any.
    METHODS send_error   IMPORTING iv_status TYPE i iv_msg TYPE string.
ENDCLASS.


CLASS zcl_bseg_api IMPLEMENTATION.

  METHOD if_http_extension~handle_request.
    mo_server = server.
    CLEAR: mv_error, mv_table, mt_dfies.

    IF server->request->get_method( ) <> 'GET'.
      send_error( iv_status = 405 iv_msg = 'Read-only API: only GET is allowed' ).
      RETURN.
    ENDIF.

    DATA(lv_path) = to_lower( server->request->get_header_field( '~path_info' ) ).
    IF strlen( lv_path ) > 1 AND lv_path CP '*/'.
      lv_path = substring( val = lv_path len = strlen( lv_path ) - 1 ).
    ENDIF.

    TRY.
        CASE lv_path.
          WHEN '/tables'.    h_tables( ).
          WHEN '/meta'.      h_meta( ).
          WHEN '/query'.     h_query( ).
          WHEN '/aggregate'. h_aggregate( ).
          WHEN '/document'.  h_document( ).
          WHEN OTHERS.
            send_error( iv_status = 404
                        iv_msg    = |Unknown path '{ lv_path }'. Use /tables /meta /query /aggregate /document| ).
        ENDCASE.
      CATCH cx_root INTO DATA(lx).
        send_error( iv_status = 500 iv_msg = lx->get_text( ) ).
    ENDTRY.
  ENDMETHOD.


  METHOD h_tables.
    TYPES: BEGIN OF ty_t, table TYPE string, description TYPE string, END OF ty_t.
    DATA lt_names TYPE STANDARD TABLE OF tabname WITH DEFAULT KEY.
    DATA lt_out   TYPE STANDARD TABLE OF ty_t WITH DEFAULT KEY.

    SPLIT c_allowed AT ',' INTO TABLE lt_names.
    SELECT tabname, ddtext FROM dd02t
      FOR ALL ENTRIES IN @lt_names
      WHERE tabname = @lt_names-table_line AND ddlanguage = @sy-langu AND as4local = 'A'
      INTO TABLE @DATA(lt_txt).

    LOOP AT lt_names INTO DATA(lv_name).
      APPEND VALUE #( table       = lv_name
                      description = VALUE #( lt_txt[ tabname = lv_name ]-ddtext OPTIONAL ) ) TO lt_out.
    ENDLOOP.
    send_json( lt_out ).
  ENDMETHOD.


  METHOD h_meta.
    TYPES: BEGIN OF ty_f,
             name        TYPE string,
             key         TYPE abap_bool,
             type        TYPE string,
             length      TYPE i,
             decimals    TYPE i,
             conversion  TYPE string,
             description TYPE string,
           END OF ty_f.
    TYPES: BEGIN OF ty_out,
             table  TYPE string,
             fields TYPE STANDARD TABLE OF ty_f WITH DEFAULT KEY,
           END OF ty_out.

    IF load_table( param( 'table' ) ) = abap_false.
      send_error( iv_status = 400 iv_msg = mv_error ).
      RETURN.
    ENDIF.

    DATA(ls_out) = VALUE ty_out( table = mv_table ).
    LOOP AT mt_dfies INTO DATA(ls_f) WHERE fieldname <> 'MANDT'.
      APPEND VALUE #( name        = ls_f-fieldname
                      key         = ls_f-keyflag
                      type        = ls_f-datatype
                      length      = ls_f-leng
                      decimals    = ls_f-decimals
                      conversion  = ls_f-convexit
                      description = ls_f-fieldtext ) TO ls_out-fields.
    ENDLOOP.
    send_json( ls_out ).
  ENDMETHOD.


  METHOD h_query.
    TYPES: BEGIN OF ty_resp,
             table TYPE string,
             count TYPE i,
             top   TYPE i,
             skip  TYPE i,
             rows  TYPE REF TO data,
           END OF ty_resp.
    FIELD-SYMBOLS <lt_data> TYPE STANDARD TABLE.

    IF load_table( param( 'table' ) ) = abap_false.
      send_error( iv_status = 400 iv_msg = mv_error ).
      RETURN.
    ENDIF.

    DATA(lt_fields) = build_fields( param( 'fields' ) ).
    DATA(lv_where)  = build_where( param( 'filter' ) ).
    DATA(lv_order)  = build_order( param( 'orderby' ) ).
    IF mv_error IS NOT INITIAL.
      send_error( iv_status = 400 iv_msg = mv_error ).
      RETURN.
    ENDIF.

    DATA(lv_top)  = CONV i( param( iv_name = 'top'  iv_default = '100' ) ).
    DATA(lv_skip) = CONV i( param( iv_name = 'skip' iv_default = '0' ) ).
    IF lv_top > c_max_rows. lv_top = c_max_rows. ENDIF.
    IF lv_top < 1.          lv_top = 1.          ENDIF.

    " Build a target table with exactly the requested columns
    DATA lt_comp TYPE abap_component_tab.
    LOOP AT lt_fields INTO DATA(lv_f).
      APPEND VALUE #( name = lv_f type = field_type( lv_f ) ) TO lt_comp.
    ENDLOOP.
    DATA(lo_tab) = cl_abap_tabledescr=>create( cl_abap_structdescr=>create( lt_comp ) ).
    DATA lr_tab TYPE REF TO data.
    CREATE DATA lr_tab TYPE HANDLE lo_tab.
    ASSIGN lr_tab->* TO <lt_data>.

    DATA(lv_select) = concat_lines_of( table = lt_fields sep = `, ` ).

    SELECT (lv_select)
      FROM (mv_table)
      WHERE (lv_where)
      ORDER BY (lv_order)
      INTO CORRESPONDING FIELDS OF TABLE @<lt_data>
      UP TO @lv_top ROWS
      OFFSET @lv_skip.

    send_json( VALUE ty_resp( table = mv_table
                              count = lines( <lt_data> )
                              top   = lv_top
                              skip  = lv_skip
                              rows  = lr_tab ) ).
  ENDMETHOD.


  METHOD h_aggregate.
    TYPES: BEGIN OF ty_resp,
             table TYPE string,
             count TYPE i,
             rows  TYPE REF TO data,
           END OF ty_resp.
    DATA lt_sel   TYPE ty_strings.
    DATA lt_cols  TYPE ty_strings.
    DATA lt_group TYPE ty_strings.
    DATA lt_comp  TYPE abap_component_tab.
    DATA lo_type  TYPE REF TO cl_abap_datadescr.
    FIELD-SYMBOLS <lt_data> TYPE STANDARD TABLE.

    IF load_table( param( 'table' ) ) = abap_false.
      send_error( iv_status = 400 iv_msg = mv_error ).
      RETURN.
    ENDIF.

    " group-by columns
    SPLIT to_upper( param( 'groupby' ) ) AT ',' INTO TABLE lt_group.
    LOOP AT lt_group ASSIGNING FIELD-SYMBOL(<g>).
      <g> = condense( <g> ).
      IF <g> IS INITIAL.
        DELETE lt_group. CONTINUE.
      ENDIF.
      IF field_exists( <g> ) = abap_false.
        send_error( iv_status = 400 iv_msg = |Unknown field '{ <g> }' in { mv_table }| ).
        RETURN.
      ENDIF.
      APPEND <g> TO lt_sel.
      APPEND <g> TO lt_cols.
      APPEND VALUE #( name = <g> type = field_type( <g> ) ) TO lt_comp.
    ENDLOOP.

    " aggregate columns: sum=, avg=, min=, max=
    DATA(lt_funcs) = VALUE ty_strings( ( `SUM` ) ( `AVG` ) ( `MIN` ) ( `MAX` ) ).
    LOOP AT lt_funcs INTO DATA(lv_func).
      SPLIT to_upper( param( to_lower( lv_func ) ) ) AT ',' INTO TABLE DATA(lt_f).
      LOOP AT lt_f INTO DATA(lv_f).
        lv_f = condense( lv_f ).
        IF lv_f IS INITIAL. CONTINUE. ENDIF.
        IF field_exists( lv_f ) = abap_false.
          send_error( iv_status = 400 iv_msg = |Unknown field '{ lv_f }' in { mv_table }| ).
          RETURN.
        ENDIF.
        DATA(lv_alias) = |{ lv_func }_{ lv_f }|.
        APPEND |{ lv_func }( { lv_f } ) AS { lv_alias }| TO lt_sel.
        APPEND lv_alias TO lt_cols.
        CASE lv_func.
          WHEN 'SUM'.
            lo_type = cl_abap_elemdescr=>get_p(
                        p_length   = 16
                        p_decimals = CONV i( mt_dfies[ fieldname = lv_f ]-decimals ) ).
          WHEN 'AVG'.
            lo_type = cl_abap_elemdescr=>get_p( p_length = 16 p_decimals = 3 ).
          WHEN OTHERS.
            lo_type = field_type( lv_f ).
        ENDCASE.
        APPEND VALUE #( name = lv_alias type = lo_type ) TO lt_comp.
      ENDLOOP.
    ENDLOOP.

    " always include a row count
    APPEND `COUNT( * ) AS CNT` TO lt_sel.
    APPEND `CNT` TO lt_cols.
    APPEND VALUE #( name = 'CNT' type = cl_abap_elemdescr=>get_i( ) ) TO lt_comp.

    DATA(lv_where) = build_where( param( 'filter' ) ).
    DATA(lv_order) = build_order( iv_order = param( 'orderby' ) it_allowed = lt_cols ).
    IF mv_error IS NOT INITIAL.
      send_error( iv_status = 400 iv_msg = mv_error ).
      RETURN.
    ENDIF.

    DATA(lv_select) = concat_lines_of( table = lt_sel   sep = `, ` ).
    DATA(lv_group)  = concat_lines_of( table = lt_group sep = `, ` ).
    IF lv_order IS INITIAL. lv_order = lv_group. ENDIF.
    DATA(lv_top) = CONV i( param( iv_name = 'top' iv_default = '1000' ) ).
    IF lv_top > c_max_rows. lv_top = c_max_rows. ENDIF.

    DATA(lo_tab) = cl_abap_tabledescr=>create( cl_abap_structdescr=>create( lt_comp ) ).
    DATA lr_tab TYPE REF TO data.
    CREATE DATA lr_tab TYPE HANDLE lo_tab.
    ASSIGN lr_tab->* TO <lt_data>.

    SELECT (lv_select)
      FROM (mv_table)
      WHERE (lv_where)
      GROUP BY (lv_group)
      ORDER BY (lv_order)
      INTO CORRESPONDING FIELDS OF TABLE @<lt_data>
      UP TO @lv_top ROWS.

    send_json( VALUE ty_resp( table = mv_table
                              count = lines( <lt_data> )
                              rows  = lr_tab ) ).
  ENDMETHOD.


  METHOD h_document.
    DATA(lv_bukrs) = CONV bukrs( to_upper( param( 'bukrs' ) ) ).
    DATA(lv_belnr) = CONV belnr_d( param( 'belnr' ) ).
    DATA(lv_gjahr) = CONV gjahr( param( 'gjahr' ) ).

    IF lv_bukrs IS INITIAL OR lv_belnr IS INITIAL OR lv_gjahr IS INITIAL.
      send_error( iv_status = 400 iv_msg = 'bukrs, belnr and gjahr are required' ).
      RETURN.
    ENDIF.
    lv_belnr = |{ lv_belnr ALPHA = IN }|.

    SELECT SINGLE bukrs, belnr, gjahr, blart, bldat, budat, monat, cpudt, usnam,
                  tcode, xblnr, bktxt, waers, kursf, bstat, stblg, stjah, awtyp, awkey
      FROM bkpf
      WHERE bukrs = @lv_bukrs AND belnr = @lv_belnr AND gjahr = @lv_gjahr
      INTO @DATA(ls_header).
    IF sy-subrc <> 0.
      send_error( iv_status = 404 iv_msg = 'Document not found' ).
      RETURN.
    ENDIF.

    SELECT buzei, bschl, koart, shkzg, hkont, kunnr, lifnr, dmbtr, wrbtr, pswsl,
           mwskz, kostl, aufnr, prctr, zuonr, sgtxt, augbl, augdt, zfbdt, zterm
      FROM bseg
      WHERE bukrs = @lv_bukrs AND belnr = @lv_belnr AND gjahr = @lv_gjahr
      ORDER BY buzei
      INTO TABLE @DATA(lt_items).

    TYPES: BEGIN OF ty_doc,
             header LIKE ls_header,
             items  LIKE lt_items,
           END OF ty_doc.
    send_json( VALUE ty_doc( header = ls_header items = lt_items ) ).
  ENDMETHOD.



  METHOD load_table.
    DATA lt_allowed TYPE ty_strings.
    DATA(lv_table) = to_upper( condense( iv_table ) ).
    SPLIT c_allowed AT ',' INTO TABLE lt_allowed.

    IF lv_table IS INITIAL OR NOT line_exists( lt_allowed[ table_line = lv_table ] ).
      mv_error = |Table '{ lv_table }' is not allowed. Allowed: { c_allowed }|.
      RETURN.
    ENDIF.
    TRY.
        DATA(lo_struct) = CAST cl_abap_structdescr( cl_abap_typedescr=>describe_by_name( lv_table ) ).
        mt_dfies = lo_struct->get_ddic_field_list( ).
      CATCH cx_root.
        mv_error = |Table { lv_table } not found in dictionary|.
        RETURN.
    ENDTRY.
    mv_table = lv_table.
    rv_ok = abap_true.
  ENDMETHOD.


  METHOD param.
    rv_val = mo_server->request->get_form_field( iv_name ).
    IF rv_val IS INITIAL AND iv_default IS SUPPLIED.
      rv_val = iv_default.
    ENDIF.
  ENDMETHOD.


  METHOD field_exists.
    rv_ok = xsdbool( line_exists( mt_dfies[ fieldname = iv_name ] ) ).
  ENDMETHOD.


  METHOD field_type.
    ro_type = CAST cl_abap_datadescr(
                cl_abap_typedescr=>describe_by_name( |{ mv_table }-{ iv_field }| ) ).
  ENDMETHOD.


  METHOD build_fields.
    DATA(lv_fields) = to_upper( condense( iv_fields ) ).
    IF lv_fields IS INITIAL OR lv_fields = '*'.
      LOOP AT mt_dfies INTO DATA(ls) WHERE fieldname <> 'MANDT'.
        APPEND CONV string( ls-fieldname ) TO rt_fields.
      ENDLOOP.
      RETURN.
    ENDIF.
    SPLIT lv_fields AT ',' INTO TABLE DATA(lt).
    LOOP AT lt INTO DATA(lv_f).
      lv_f = condense( lv_f ).
      IF lv_f IS INITIAL. CONTINUE. ENDIF.
      IF field_exists( lv_f ) = abap_false.
        mv_error = |Unknown field '{ lv_f }' in { mv_table }|.
        RETURN.
      ENDIF.
      APPEND lv_f TO rt_fields.
    ENDLOOP.
  ENDMETHOD.


  METHOD build_where.
    DATA lt_conds TYPE ty_strings.
    DATA lt_sql   TYPE ty_strings.
    DATA lv_field TYPE string.
    DATA lv_op    TYPE string.
    DATA lv_val   TYPE string.

    IF iv_filter IS INITIAL. RETURN. ENDIF.
    SPLIT iv_filter AT ';' INTO TABLE DATA(lt_parts).

    LOOP AT lt_parts INTO DATA(lv_part).
      DATA(lv_cond) = condense( lv_part ).
      IF lv_cond IS INITIAL. CONTINUE. ENDIF.

      FIND REGEX '^(\w+)\s+(eq|ne|gt|ge|lt|le|cp|np|in|bt)\s+(.+)$'
        IN lv_cond IGNORING CASE
        SUBMATCHES lv_field lv_op lv_val.
      IF sy-subrc <> 0.
        mv_error = |Bad filter '{ lv_cond }'. Expected: field op value, e.g. bukrs eq 1000|.
        RETURN.
      ENDIF.
      lv_field = to_upper( lv_field ).
      lv_op    = to_lower( lv_op ).
      lv_val   = condense( lv_val ).
      IF field_exists( lv_field ) = abap_false.
        mv_error = |Unknown field '{ lv_field }' in { mv_table }|.
        RETURN.
      ENDIF.

      CASE lv_op.
        WHEN 'eq'. APPEND |{ lv_field } = { sql_value( iv_field = lv_field iv_value = lv_val ) }| TO lt_conds.
        WHEN 'ne'. APPEND |{ lv_field } <> { sql_value( iv_field = lv_field iv_value = lv_val ) }| TO lt_conds.
        WHEN 'gt'. APPEND |{ lv_field } > { sql_value( iv_field = lv_field iv_value = lv_val ) }| TO lt_conds.
        WHEN 'ge'. APPEND |{ lv_field } >= { sql_value( iv_field = lv_field iv_value = lv_val ) }| TO lt_conds.
        WHEN 'lt'. APPEND |{ lv_field } < { sql_value( iv_field = lv_field iv_value = lv_val ) }| TO lt_conds.
        WHEN 'le'. APPEND |{ lv_field } <= { sql_value( iv_field = lv_field iv_value = lv_val ) }| TO lt_conds.
        WHEN 'cp' OR 'np'.
          REPLACE ALL OCCURRENCES OF '*' IN lv_val WITH '%'.
          REPLACE ALL OCCURRENCES OF '+' IN lv_val WITH '_'.
          DATA(lv_not) = COND string( WHEN lv_op = 'np' THEN `NOT ` ELSE `` ).
          APPEND |{ lv_field } { lv_not }LIKE { cl_abap_dyn_prg=>quote( lv_val ) }| TO lt_conds.
        WHEN 'in'.
          SPLIT lv_val AT ',' INTO TABLE DATA(lt_vals).
          CLEAR lt_sql.
          LOOP AT lt_vals INTO DATA(lv_v).
            APPEND sql_value( iv_field = lv_field iv_value = lv_v ) TO lt_sql.
          ENDLOOP.
          APPEND |{ lv_field } IN ( { concat_lines_of( table = lt_sql sep = `, ` ) } )| TO lt_conds.
        WHEN 'bt'.
          SPLIT lv_val AT ',' INTO DATA(lv_lo) DATA(lv_hi).
          APPEND |{ lv_field } BETWEEN { sql_value( iv_field = lv_field iv_value = lv_lo ) }| &&
                 | AND { sql_value( iv_field = lv_field iv_value = lv_hi ) }| TO lt_conds.
      ENDCASE.
      IF mv_error IS NOT INITIAL. RETURN. ENDIF.
    ENDLOOP.

    rv_where = concat_lines_of( table = lt_conds sep = ` AND ` ).
  ENDMETHOD.


  METHOD build_order.
    DATA lt TYPE ty_strings.
    IF iv_order IS INITIAL.
      IF it_allowed IS NOT SUPPLIED.
        " default: primary key so OFFSET paging is deterministic
        LOOP AT mt_dfies INTO DATA(ls) WHERE keyflag = abap_true AND fieldname <> 'MANDT'.
          APPEND CONV string( ls-fieldname ) TO lt.
        ENDLOOP.
      ENDIF.
    ELSE.
      SPLIT to_upper( iv_order ) AT ',' INTO TABLE DATA(lt_parts).
      LOOP AT lt_parts INTO DATA(lv_part).
        SPLIT condense( lv_part ) AT space INTO DATA(lv_f) DATA(lv_dir).
        DATA(lv_ok) = COND abap_bool(
          WHEN it_allowed IS SUPPLIED THEN xsdbool( line_exists( it_allowed[ table_line = lv_f ] ) )
          ELSE field_exists( lv_f ) ).
        IF lv_ok = abap_false.
          mv_error = |Unknown orderby field '{ lv_f }'|.
          RETURN.
        ENDIF.
        IF lv_dir = 'DESC'.
          lv_f = |{ lv_f } DESCENDING|.
        ENDIF.
        APPEND lv_f TO lt.
      ENDLOOP.
    ENDIF.
    rv_order = concat_lines_of( table = lt sep = `, ` ).
  ENDMETHOD.


  METHOD sql_value.
    DATA lr_val TYPE REF TO data.
    FIELD-SYMBOLS <lv> TYPE any.

    DATA(ls_f)   = mt_dfies[ fieldname = iv_field ].
    DATA(lv_val) = condense( iv_value ).

    " apply the field's input conversion (ALPHA padding for BELNR, HKONT, KUNNR, ...)
    IF ls_f-convexit IS NOT INITIAL.
      DATA(lv_typename) = |{ mv_table }-{ iv_field }|.
      CREATE DATA lr_val TYPE (lv_typename).
      ASSIGN lr_val->* TO <lv>.
      DATA(lv_fm) = |CONVERSION_EXIT_{ ls_f-convexit }_INPUT|.
      TRY.
          CALL FUNCTION lv_fm
            EXPORTING  input  = lv_val
            IMPORTING  output = <lv>
            EXCEPTIONS OTHERS = 1.
          IF sy-subrc = 0.
            lv_val = <lv>.
          ENDIF.
        CATCH cx_root.
          " exit not callable this way; keep raw value
      ENDTRY.
    ENDIF.

    CASE ls_f-datatype.
      WHEN 'CURR' OR 'DEC' OR 'QUAN' OR 'FLTP' OR 'INT1' OR 'INT2' OR 'INT4' OR 'INT8'.
        FIND REGEX '^-?\d+(\.\d+)?$' IN lv_val.
        IF sy-subrc <> 0.
          mv_error = |Value '{ lv_val }' is not numeric for field { iv_field }|.
          rv_sql = '0'.
          RETURN.
        ENDIF.
        rv_sql = lv_val.
      WHEN OTHERS.
        rv_sql = cl_abap_dyn_prg=>quote( lv_val ).
    ENDCASE.
  ENDMETHOD.


  METHOD send.
    mo_server->response->set_content_type( 'application/json; charset=utf-8' ).
    mo_server->response->set_cdata( iv_body ).
    mo_server->response->set_status( code = iv_status reason = 'OK' ).
  ENDMETHOD.


  METHOD send_json.
    send( iv_status = 200
          iv_body   = /ui2/cl_json=>serialize(
                        data        = ia_data
                        pretty_name = /ui2/cl_json=>pretty_mode-low_case ) ).
  ENDMETHOD.


  METHOD send_error.
    DATA(lv_msg) = iv_msg.
    REPLACE ALL OCCURRENCES OF '"' IN lv_msg WITH '\"'.
    mo_server->response->set_content_type( 'application/json; charset=utf-8' ).
    mo_server->response->set_cdata( |\{"error":"{ lv_msg }"\}| ).
    mo_server->response->set_status( code = iv_status reason = 'Error' ).
  ENDMETHOD.

ENDCLASS.
