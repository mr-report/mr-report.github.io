-- SÓ PARA TESTE LOCAL: cria 10 dias anteriores a partir do relatório real da Fernanda,
-- com troca de dieta 5 dias atrás nas baias A-*, para testar a curva da baia.
do $$
declare k int;
begin
  for k in 1..10 loop
    insert into relatorios(fazenda_id,data_ref,confinamento,arquivo,message_id,n_baias,n_cab)
      select fazenda_id, data_ref-k, confinamento, 'teste', 'teste'||k, n_baias, n_cab from relatorios
      where fazenda_id='fernanda' and data_ref='2026-11-16' on conflict do nothing;
    insert into baias_dia
      select fazenda_id, data_ref-k, curral, lote, cab, ct, sub_contrato, dt_entrada, dias_conf-k,
        ms_5d, mn_5d, round(ms_1d*(1-0.004*k)::numeric,2), mn_1d, ms_med, mn_med,
        case when curral like 'A-%' and k>=5 then 'ADAPTAÇÃO 3.0' else racao end, greatest(racao_dias-k,1), racao_tipo_dias,
        peso_entrada, peso_atual_prj-1.4*k, ims_pv_5d, ims_pv_1d, ims_pv_med,
        cons_dia_mn, round((cons_dia_ms*(1-0.004*k) + (random()-0.5)*0.3)::numeric,2), round((cons_dia_pv*(1-0.002*k))::numeric,2),
        dt_abate, cocho_d2, cocho_d3, 1.0
      from baias_dia where fazenda_id='fernanda' and data_ref='2026-11-16' on conflict do nothing;
  end loop;
end $$;
