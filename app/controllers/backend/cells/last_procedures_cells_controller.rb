class Backend::Cells::LastProceduresCellsController < Backend::CellsController

  def show

    @procedure = Procedure.last
    production = Production.find(@procedure.production_id)
    target = ProcedureVariable.find_by_procedure_id_and_role(@procedure.id,"target")
    container = Product.find(target.target_id)
    #if container.is_a?(CultivableLandParcel)
      #@container = container.class.find(container.id)
    if container.is_a?(Plant)
      @container = CultivableLandParcel.find(container.current_place_id)
    else
      @container = container
    end


  end

end
